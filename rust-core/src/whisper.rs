//! Whisper-based detector. Transcribes the (downmixed, 16 kHz) audio in rolling
//! windows with whisper.cpp and reports any word in the censor list, using
//! whisper's per-token timestamps to place the censor span. This is far more
//! robust to music-mixed vocals than the tiny keyword spotter, which mis-hears
//! words buried under a beat.
//!
//! Matching is plain text (case-insensitive, exact word), so the word list needs
//! no tokenisation — any word works the moment it's added.

use crate::{Detection, Detector, DetectorTiming, MockDetector, ThreadedDetector};
use std::collections::HashSet;
use std::sync::Arc;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState};

const SAMPLE_RATE: u32 = 16_000;
const CS: u64 = SAMPLE_RATE as u64 / 100; // samples per whisper centisecond timestamp

/// Returns the whisper detector on a worker thread, or an inert detector (pass-
/// through delay) if the model / word list can't be loaded.
pub fn default_detector(timing: Arc<DetectorTiming>) -> Box<dyn Detector> {
    match WhisperDetector::from_env(timing) {
        Ok(d) => Box::new(ThreadedDetector::new(d)),
        Err(e) => {
            eprintln!("[swearcore] whisper detector disabled ({e}); running as pass-through delay.");
            Box::new(MockDetector::inert(SAMPLE_RATE))
        }
    }
}

struct WhisperDetector {
    state: WhisperState, // owns an Arc to the model context
    words: HashSet<String>,
    timing: Arc<DetectorTiming>,
    buf: Vec<f32>,        // rolling audio window
    buf_start: u64,       // absolute sample index of buf[0]
    seen: u64,            // total samples consumed
    last_run: u64,        // `seen` at last transcription
    recent: Vec<(String, u64)>, // (word, abs_start) already emitted — for dedup across windows
    window: usize,        // transcription window length, samples
    step: u64,            // run cadence, samples
    edge: u64,            // ignore words ending within this of the window's trailing edge
}

// Used only on the single ThreadedDetector worker thread (moved there once).
unsafe impl Send for WhisperDetector {}

impl WhisperDetector {
    fn from_env(timing: Arc<DetectorTiming>) -> Result<Self, String> {
        let model = std::env::var("SWEAR_WHISPER_MODEL").map_err(|_| "SWEAR_WHISPER_MODEL unset".to_string())?;
        let words_file = std::env::var("SWEAR_WORDS_FILE").map_err(|_| "SWEAR_WORDS_FILE unset".to_string())?;
        let text = std::fs::read_to_string(&words_file).map_err(|e| format!("read {words_file}: {e}"))?;
        let words: HashSet<String> = text
            .lines()
            .map(|l| clean(l.trim()))
            .filter(|w| !w.is_empty())
            .collect();
        if words.is_empty() {
            return Err("word list is empty".into());
        }
        let ctx = WhisperContext::new_with_params(&model, WhisperContextParameters::default())
            .map_err(|e| format!("load whisper model {model}: {e}"))?;
        let state = ctx.create_state().map_err(|e| format!("create whisper state: {e}"))?;

        Ok(Self {
            state,
            words,
            timing,
            buf: Vec::with_capacity(SAMPLE_RATE as usize * 12),
            buf_start: 0,
            seen: 0,
            last_run: 0,
            recent: Vec::new(),
            // Rolling-window timings. The engine's output *delay* must exceed the
            // detection lag (≈ word length + `edge` + `step` + transcription
            // time). Transcribing an ~8 s window with small.en takes roughly:
            //   M3/M4 Max   ~0.3 s   → min usable delay ~2.5 s
            //   M-series Pro ~0.5 s  → min usable delay ~3.0 s   (the app default)
            //   base M1/M2  ~0.7–0.9 s → min usable delay ~3.5 s
            // (rough, single-core-ish estimates). On a faster chip you can lower
            // the delay to cut lag; raise it if words slip through. Smaller `step`
            // also lowers lag but runs Whisper more often (more CPU/heat).
            window: SAMPLE_RATE as usize * 8,    // 8 s window for context
            step: SAMPLE_RATE as u64 * 6 / 5,    // run every 1.2 s
            edge: SAMPLE_RATE as u64 * 2 / 5,     // 0.4 s trailing guard
        })
    }

    /// Transcribe the current buffer and return newly-matched word spans.
    fn transcribe(&mut self) -> Vec<Detection> {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(Some("en"));
        params.set_token_timestamps(true);
        params.set_no_context(true);
        params.set_suppress_blank(true);
        params.set_n_threads(4);
        params.set_print_realtime(false);
        params.set_print_progress(false);
        params.set_print_timestamps(false);
        params.set_print_special(false);
        if self.state.full(params, &self.buf).is_err() {
            return Vec::new();
        }

        // Phase 1 — collect (word, abs_start, abs_end) from the transcript. This
        // only borrows `self.state` (via the segment), so it can't also mutate
        // `self`; matching/dedup happens in phase 2 once that borrow is dropped.
        let mut candidates: Vec<(String, u64, u64)> = Vec::new();
        for si in 0..self.state.full_n_segments() {
            let Some(seg) = self.state.get_segment(si) else { continue };
            let mut word = String::new();
            let (mut w_start, mut w_end) = (0i64, 0i64);
            for ti in 0..seg.n_tokens() {
                let Some(tok) = seg.get_token(ti) else { continue };
                let txt = tok.to_str().unwrap_or("");
                if txt.starts_with("[_") {
                    continue; // special token
                }
                let d = tok.token_data();
                if txt.starts_with(' ') && !word.is_empty() {
                    push_word(&mut word, w_start, w_end, self.buf_start, &mut candidates);
                }
                if word.is_empty() {
                    w_start = d.t0;
                }
                word.push_str(txt);
                w_end = d.t1;
            }
            push_word(&mut word, w_start, w_end, self.buf_start, &mut candidates);
        }

        // Phase 2 — match against the list, drop trailing-edge and duplicate hits.
        let preroll = Self::ms_to_samples(self.timing.postroll_ms().min(200) + 100);
        let postroll = Self::ms_to_samples(self.timing.postroll_ms());
        let finalize_before = self.seen.saturating_sub(self.edge);
        let mut hits = Vec::new();
        for (w, a, b) in candidates {
            if b > finalize_before || !self.matches(&w) || self.recently_emitted(&w, a) {
                continue;
            }
            self.recent.push((w, a));
            hits.push(Detection { start: a.saturating_sub(preroll), end: b + postroll });
        }

        // Forget dedup entries older than the window.
        let cutoff = self.seen.saturating_sub(self.window as u64);
        self.recent.retain(|(_, t)| *t >= cutoff);
        hits
    }

    /// Does a transcribed word match the censor list?
    /// 1. Exact match.
    /// 2. Elongation (any length): the word is a list word with letters repeated,
    ///    e.g. "fuuuck", "shiiit", "biiitch", "asss". Safe even for short words —
    ///    it only repeats the word's own letters in order, never substitutes, so
    ///    "ship"≠"shit", "duck"≠"...", "as"≠"ass".
    /// 3. One-edit fuzzy (length ≥ 6, same first letter): genuine near-misses like
    ///    "fuckin"→"fucking". Gated to long words because one edit on a short word
    ///    would censor innocents.
    fn matches(&self, w: &str) -> bool {
        let wb = w.as_bytes();
        if self.words.contains(w) || self.words.iter().any(|kw| elongation_match(wb, kw.as_bytes())) {
            return true;
        }
        if w.len() < 6 {
            return false;
        }
        let first = wb[0];
        self.words.iter().any(|kw| {
            kw.len() >= 6 && kw.as_bytes()[0] == first && within_one_edit(w, kw)
        })
    }

    fn recently_emitted(&self, word: &str, abs_start: u64) -> bool {
        // Same word within ~0.8 s is the same utterance seen in an overlapping
        // window (timestamps jitter between windows). Distinct repeats of a word
        // in real speech are further apart than this.
        self.recent.iter().any(|(w, t)| w == word && abs_start.abs_diff(*t) < SAMPLE_RATE as u64 * 4 / 5)
    }

    #[inline]
    fn ms_to_samples(ms: u32) -> u64 {
        ms as u64 * SAMPLE_RATE as u64 / 1000
    }
}

impl Detector for WhisperDetector {
    fn sample_rate(&self) -> u32 {
        SAMPLE_RATE
    }

    fn feed(&mut self, mono: &[f32]) -> Vec<Detection> {
        self.buf.extend_from_slice(mono);
        self.seen += mono.len() as u64;

        // Run periodically once there's enough audio.
        if self.seen - self.last_run < self.step || self.buf.len() < SAMPLE_RATE as usize * 2 {
            return Vec::new();
        }
        self.last_run = self.seen;
        let hits = self.transcribe();

        // Keep only the last `window` samples buffered.
        if self.buf.len() > self.window {
            let drop = self.buf.len() - self.window;
            self.buf.drain(0..drop);
            self.buf_start += drop as u64;
        }
        hits
    }
}

/// Finalise the accumulating `word`: clean it, and if non-empty push it (with
/// absolute sample span from its token centisecond timestamps) onto `out`.
fn push_word(word: &mut String, t0: i64, t1: i64, buf_start: u64, out: &mut Vec<(String, u64, u64)>) {
    let w = clean(word);
    word.clear();
    if !w.is_empty() {
        out.push((w, buf_start + (t0.max(0) as u64) * CS, buf_start + (t1.max(0) as u64) * CS));
    }
}

/// True if `cand` is `sw` with one or more letters held longer ("fuuuck" for
/// "fuck", "asss" for "ass"). Walks both as runs of identical bytes: every run
/// in `sw` must appear in `cand`, same letter and in order, with at least as many
/// repeats. No substitutions, so it never matches a different word.
fn elongation_match(cand: &[u8], sw: &[u8]) -> bool {
    let (mut i, mut k) = (0usize, 0usize);
    while k < sw.len() {
        let c = sw[k];
        let mut sw_run = 0;
        while k < sw.len() && sw[k] == c {
            sw_run += 1;
            k += 1;
        }
        if i >= cand.len() || cand[i] != c {
            return false;
        }
        let mut cand_run = 0;
        while i < cand.len() && cand[i] == c {
            cand_run += 1;
            i += 1;
        }
        if cand_run < sw_run {
            return false;
        }
    }
    i == cand.len() && !sw.is_empty()
}

/// True if `a` and `b` are within one edit (substitution, insertion, or
/// deletion) — a cheap Levenshtein ≤ 1 over ascii bytes.
fn within_one_edit(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let (la, lb) = (a.len(), b.len());
    if la.abs_diff(lb) > 1 {
        return false;
    }
    if la == lb {
        return a.iter().zip(b).filter(|(x, y)| x != y).count() <= 1;
    }
    // Lengths differ by one: walk both, allowing a single skip in the longer.
    let (short, long) = if la < lb { (a, b) } else { (b, a) };
    let (mut i, mut j, mut edits) = (0usize, 0usize, 0u32);
    while i < short.len() && j < long.len() {
        if short[i] == long[j] {
            i += 1;
            j += 1;
        } else {
            j += 1;
            edits += 1;
            if edits > 1 {
                return false;
            }
        }
    }
    true
}

/// Lowercase and keep only ascii letters/digits (drops punctuation/spaces) so
/// "Bitch," and "bitch" match the same list entry.
fn clean(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(|c| c.to_lowercase())
        .collect()
}
