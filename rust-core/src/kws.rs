//! Streaming keyword-spotter detector backed by sherpa-onnx (Next-gen Kaldi).
//!
//! Enabled by the `sherpa` feature. This is the SOTA-for-latency path: a
//! streaming Zipformer transducer in keyword-spotting mode (~160 ms at
//! chunk-8, ~320 ms at chunk-16), fed a configurable word list — far better
//! suited to "spot these N words now" than Whisper, which is an offline
//! architecture with multi-second streaming latency.
//!
//! `sherpa-rs` 0.6's safe `keyword_spot::KeywordSpot` wrapper is one-shot: its
//! `extract_keyword` calls `InputFinished` on every invocation, which closes the
//! online stream to further audio. A live censor needs the *continuous*
//! streaming flow (accept_waveform → decode while ready → get_result → reset on
//! hit), so we drive the C API directly through the re-exported `sherpa_rs_sys`.
//! Wire up against a real model via `scripts/fetch-model.sh`.

use crate::{Detection, Detector, DetectorTiming, MockDetector, ThreadedDetector};
use sherpa_rs::sherpa_rs_sys as sys;
use std::ffi::{CStr, CString};
use std::mem;
use std::path::PathBuf;
use std::sync::Arc;

/// Returns the keyword-spotter on its own worker thread, or — if the model
/// isn't installed / fails to load — an inert detector so the app still runs as
/// a transparent delay instead of failing to start. `timing` is the live,
/// UI-adjustable reach-back configuration shared with the FFI control surface.
pub fn default_detector(timing: Arc<DetectorTiming>, sensitivity: f32) -> Box<dyn Detector> {
    match KwsDetector::from_env(timing, sensitivity) {
        Ok(kws) => Box::new(ThreadedDetector::new(kws)),
        Err(e) => {
            eprintln!("[swearcore] keyword-spotter disabled ({e}); running as pass-through delay. \
                       Set SWEAR_KWS_DIR to a sherpa-onnx KWS model directory.");
            Box::new(MockDetector::inert(SAMPLE_RATE))
        }
    }
}

const SAMPLE_RATE: u32 = 16_000;
const FEATURE_DIM: i32 = 80;

struct KwsDetector {
    spotter: *const sys::SherpaOnnxKeywordSpotter,
    stream: *const sys::SherpaOnnxOnlineStream,
    seen: u64, // mono samples consumed at SAMPLE_RATE
    /// Live, UI-adjustable reach-back timing (ms-per-char, latency margin,
    /// postroll), read fresh on every hit.
    timing: Arc<DetectorTiming>,
}

impl KwsDetector {
    #[inline]
    fn ms_to_frames(ms: u32) -> u64 {
        ms as u64 * SAMPLE_RATE as u64 / 1000
    }
}

// The spotter/stream pointers are owned solely by this detector and only ever
// touched from the single `ThreadedDetector` worker thread (the detector is
// moved there once and never shared). Mirrors the crate's own `KeywordSpot`.
unsafe impl Send for KwsDetector {}

impl KwsDetector {
    fn from_env(timing: Arc<DetectorTiming>, sensitivity: f32) -> Result<Self, String> {
        // Map a 0..1 sensitivity to the spotter's trigger threshold (lower =
        // easier to fire) and keyword score (higher = stronger boost). More
        // sensitivity helps catch words buried under music, at the cost of more
        // false positives.
        let s = sensitivity.clamp(0.0, 1.0);
        let keywords_threshold = 0.30 - 0.28 * s; // 0.30 (cautious) .. 0.02 (hot)
        let keywords_score = 1.0 + 4.0 * s; //        1.0          .. 5.0

        let dir = PathBuf::from(
            std::env::var("SWEAR_KWS_DIR").map_err(|_| "SWEAR_KWS_DIR unset".to_string())?,
        );
        // CStrings must outlive the Create call below; sherpa copies them into
        // its own std::strings during construction, so locals are sufficient.
        let cpath = |name: &str| -> Result<CString, String> {
            CString::new(dir.join(name).to_string_lossy().into_owned())
                .map_err(|e| format!("bad path for {name}: {e}"))
        };
        let encoder = cpath("encoder.onnx")?;
        let decoder = cpath("decoder.onnx")?;
        let joiner = cpath("joiner.onnx")?;
        let tokens = cpath("tokens.txt")?;
        // The keyword file is user-editable, so it lives outside the (read-only,
        // code-signed) model dir when SWEAR_KEYWORDS_FILE points elsewhere.
        let keywords_path = std::env::var("SWEAR_KEYWORDS_FILE")
            .unwrap_or_else(|_| dir.join("keywords.txt").to_string_lossy().into_owned());
        let keywords = CString::new(keywords_path).map_err(|e| format!("bad keywords path: {e}"))?;
        let provider = CString::new("cpu").unwrap();

        let config = sys::SherpaOnnxKeywordSpotterConfig {
            feat_config: sys::SherpaOnnxFeatureConfig {
                sample_rate: SAMPLE_RATE as i32,
                feature_dim: FEATURE_DIM,
            },
            keywords_buf: std::ptr::null(),
            keywords_buf_size: 0,
            keywords_file: keywords.as_ptr(),
            max_active_paths: 4,
            keywords_score,
            keywords_threshold,
            num_trailing_blanks: 1,
            model_config: sys::SherpaOnnxOnlineModelConfig {
                transducer: sys::SherpaOnnxOnlineTransducerModelConfig {
                    encoder: encoder.as_ptr(),
                    decoder: decoder.as_ptr(),
                    joiner: joiner.as_ptr(),
                },
                num_threads: 1,
                provider: provider.as_ptr(),
                debug: 0,
                tokens: tokens.as_ptr(),
                // Unused model families for this transducer KWS config.
                paraformer: unsafe { mem::zeroed() },
                zipformer2_ctc: unsafe { mem::zeroed() },
                model_type: std::ptr::null(),
                modeling_unit: std::ptr::null(),
                bpe_vocab: std::ptr::null(),
                tokens_buf: std::ptr::null(),
                tokens_buf_size: 0,
                nemo_ctc: unsafe { mem::zeroed() },
            },
        };

        let spotter = unsafe { sys::SherpaOnnxCreateKeywordSpotter(&config) };
        if spotter.is_null() {
            return Err("CreateKeywordSpotter failed (check model files in SWEAR_KWS_DIR)".into());
        }
        let stream = unsafe { sys::SherpaOnnxCreateKeywordStream(spotter) };
        if stream.is_null() {
            unsafe { sys::SherpaOnnxDestroyKeywordSpotter(spotter) };
            return Err("CreateKeywordStream failed".into());
        }

        Ok(Self { spotter, stream, seen: 0, timing })
    }

    /// Estimated spoken length of `keyword`, in detector frames, from its letter
    /// count and the live speech-rate setting. (The spotter's own timestamps are
    /// unreliable here — their origin shifts on the per-hit stream reset.)
    fn estimated_word_frames(&self, keyword: &str) -> u64 {
        let letters = keyword.chars().filter(|c| c.is_alphanumeric()).count() as u64;
        letters * Self::ms_to_frames(self.timing.ms_per_char())
    }
}

impl Detector for KwsDetector {
    fn sample_rate(&self) -> u32 {
        SAMPLE_RATE
    }

    fn feed(&mut self, mono: &[f32]) -> Vec<Detection> {
        self.seen += mono.len() as u64;
        let mut hits = Vec::new();
        unsafe {
            sys::SherpaOnnxOnlineStreamAcceptWaveform(
                self.stream,
                SAMPLE_RATE as i32,
                mono.as_ptr(),
                mono.len() as i32,
            );
            while sys::SherpaOnnxIsKeywordStreamReady(self.spotter, self.stream) == 1 {
                sys::SherpaOnnxDecodeKeywordStream(self.spotter, self.stream);
                let result = sys::SherpaOnnxGetKeywordResult(self.spotter, self.stream);
                if result.is_null() {
                    continue;
                }
                let keyword = if (*result).keyword.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr((*result).keyword).to_string_lossy().into_owned()
                };
                if !keyword.is_empty() {
                    // The spotter fires ~latency_margin *after* the word ends, so
                    // the word sits at roughly [seen-latency-word, seen-latency].
                    // Anchor the cut at that estimated word end — NOT at `seen`,
                    // which is a whole detector-latency late and was padding every
                    // hit with ~latency+postroll of trailing silence. The span is
                    // then just the word (estimated from its text) plus a short tail.
                    let word_frames = self.estimated_word_frames(&keyword);
                    let latency_margin = Self::ms_to_frames(self.timing.latency_margin_ms());
                    let postroll = Self::ms_to_frames(self.timing.postroll_ms());
                    let word_end = self.seen.saturating_sub(latency_margin);
                    let start = word_end.saturating_sub(word_frames);
                    let end = word_end + postroll;
                    hits.push(Detection { start, end });
                    // Clear the matched keyword so the next word starts fresh.
                    sys::SherpaOnnxResetKeywordStream(self.spotter, self.stream);
                }
                sys::SherpaOnnxDestroyKeywordResult(result);
            }
        }
        hits
    }
}

impl Drop for KwsDetector {
    fn drop(&mut self) {
        unsafe {
            sys::SherpaOnnxDestroyOnlineStream(self.stream);
            sys::SherpaOnnxDestroyKeywordSpotter(self.spotter);
        }
    }
}
