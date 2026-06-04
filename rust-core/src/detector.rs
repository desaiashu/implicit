//! Detection interface + helpers.
//!
//! A [`Detector`] consumes mono audio at its own native rate and reports spans
//! (in detector-rate frames) that match the target word list. The engine owns
//! downmix + resampling and converts spans back to device frames.
//!
//! [`ThreadedDetector`] wraps any detector so its (heavy, allocating) inference
//! runs on a worker thread — the audio thread only hands off samples and polls
//! for results, never blocking on the model. The real sherpa keyword-spotter
//! (see `kws.rs`) is always wrapped in one of these before reaching the engine.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::thread::JoinHandle;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Detection {
    /// Half-open span in detector-rate frames, measured from stream start.
    pub start: u64,
    pub end: u64,
}

/// Live-tunable detection timing, shared (behind an `Arc`) between the FFI
/// control surface and the worker-thread detector so the UI can adjust it
/// without rebuilding the model. All values in milliseconds; reads/writes are
/// lock-free atomics safe to touch from any thread.
pub struct DetectorTiming {
    ms_per_char: AtomicU32,
    latency_margin_ms: AtomicU32,
    postroll_ms: AtomicU32,
}

impl DetectorTiming {
    pub fn new(ms_per_char: u32, latency_margin_ms: u32, postroll_ms: u32) -> Self {
        Self {
            ms_per_char: AtomicU32::new(ms_per_char),
            latency_margin_ms: AtomicU32::new(latency_margin_ms),
            postroll_ms: AtomicU32::new(postroll_ms),
        }
    }
    pub fn ms_per_char(&self) -> u32 { self.ms_per_char.load(Ordering::Relaxed) }
    pub fn latency_margin_ms(&self) -> u32 { self.latency_margin_ms.load(Ordering::Relaxed) }
    pub fn postroll_ms(&self) -> u32 { self.postroll_ms.load(Ordering::Relaxed) }

    pub fn set_ms_per_char(&self, v: u32) { self.ms_per_char.store(v, Ordering::Relaxed); }
    pub fn set_latency_margin_ms(&self, v: u32) { self.latency_margin_ms.store(v, Ordering::Relaxed); }
    pub fn set_postroll_ms(&self, v: u32) { self.postroll_ms.store(v, Ordering::Relaxed); }
}

pub trait Detector: Send {
    /// Native mono sample rate the detector consumes (e.g. 16000).
    fn sample_rate(&self) -> u32;
    /// Feed mono samples at `sample_rate()`. Returns any spans recognised this
    /// call; may buffer internally and return an empty vec most of the time.
    fn feed(&mut self, mono: &[f32]) -> Vec<Detection>;
}

/// Deterministic detector for tests and the "no model" build: fires one fixed
/// span the first time the running sample count crosses `trigger_at`.
pub struct MockDetector {
    rate: u32,
    seen: u64,
    fired: bool,
    trigger_at: u64,
    span: u64,
}

impl MockDetector {
    pub fn new(rate: u32, trigger_at: u64, span: u64) -> Self {
        Self { rate: rate.max(1), seen: 0, fired: false, trigger_at, span }
    }
    /// A detector that never fires — the engine becomes a transparent delay.
    pub fn inert(rate: u32) -> Self {
        Self::new(rate, u64::MAX, 0)
    }
}

impl Detector for MockDetector {
    fn sample_rate(&self) -> u32 {
        self.rate
    }
    fn feed(&mut self, mono: &[f32]) -> Vec<Detection> {
        let before = self.seen;
        self.seen += mono.len() as u64;
        if !self.fired && self.seen >= self.trigger_at {
            self.fired = true;
            let start = self.trigger_at.max(before);
            return vec![Detection { start, end: start + self.span }];
        }
        Vec::new()
    }
}

/// Runs an inner detector on a dedicated thread. `feed` hands samples to the
/// worker and drains any ready detections without blocking on inference.
///
/// NOTE: std `mpsc` is not a hard real-time queue (the send allocates), which is
/// fine for a personal tool. If dropouts appear under load, swap the channels
/// for a preallocated lock-free SPSC ring (e.g. `rtrb`).
pub struct ThreadedDetector {
    rate: u32,
    to_worker: Sender<Vec<f32>>,
    from_worker: Receiver<Detection>,
    worker: Option<JoinHandle<()>>,
}

impl ThreadedDetector {
    pub fn new<D: Detector + 'static>(mut inner: D) -> Self {
        let rate = inner.sample_rate();
        let (to_worker, rx_samples) = std::sync::mpsc::channel::<Vec<f32>>();
        let (tx_det, from_worker) = std::sync::mpsc::channel::<Detection>();
        let worker = std::thread::Builder::new()
            .name("swear-detector".into())
            .spawn(move || {
                while let Ok(chunk) = rx_samples.recv() {
                    for det in inner.feed(&chunk) {
                        if tx_det.send(det).is_err() {
                            return;
                        }
                    }
                }
            })
            .expect("spawn detector thread");
        Self { rate, to_worker, from_worker, worker: Some(worker) }
    }
}

impl Detector for ThreadedDetector {
    fn sample_rate(&self) -> u32 {
        self.rate
    }
    fn feed(&mut self, mono: &[f32]) -> Vec<Detection> {
        // Hand off (ignore error if the worker died) and drain ready results.
        let _ = self.to_worker.send(mono.to_vec());
        self.from_worker.try_iter().collect()
    }
}

impl Drop for ThreadedDetector {
    fn drop(&mut self) {
        // Dropping the sender ends the worker's recv loop.
        let (dead, _) = std::sync::mpsc::channel();
        self.to_worker = dead;
        if let Some(h) = self.worker.take() {
            let _ = h.join();
        }
    }
}

/// Downmix interleaved audio to mono (channel average) into `out`.
pub fn downmix(input: &[f32], channels: usize, out: &mut Vec<f32>) {
    out.clear();
    if channels <= 1 {
        out.extend_from_slice(input);
        return;
    }
    let frames = input.len() / channels;
    out.reserve(frames);
    for f in 0..frames {
        let base = f * channels;
        let sum: f32 = input[base..base + channels].iter().sum();
        out.push(sum / channels as f32);
    }
}

/// Stateful linear resampler (mono). Adequate to feed a robust keyword-spotter;
/// swap for a windowed-sinc resampler if detection accuracy needs it.
pub struct LinearResampler {
    ratio: f64, // in_rate / out_rate
    pos: f64,   // fractional source position within the current input interval
    last: f32,
    identity: bool,
}

impl LinearResampler {
    pub fn new(in_rate: u32, out_rate: u32) -> Self {
        let ratio = in_rate as f64 / out_rate.max(1) as f64;
        Self { ratio, pos: 0.0, last: 0.0, identity: (ratio - 1.0).abs() < 1e-9 }
    }

    pub fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if self.identity {
            out.extend_from_slice(input);
            return;
        }
        for &x in input {
            while self.pos < 1.0 {
                out.push(self.last + (x - self.last) * self.pos as f32);
                self.pos += self.ratio;
            }
            self.pos -= 1.0;
            self.last = x;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_averages_channels() {
        let mut out = Vec::new();
        downmix(&[1.0, 3.0, -2.0, 2.0], 2, &mut out);
        assert_eq!(out, vec![2.0, 0.0]);
    }

    #[test]
    fn resampler_downsamples_to_expected_length() {
        let mut r = LinearResampler::new(48_000, 16_000);
        let input = vec![1.0f32; 4800]; // 0.1s at 48k
        let mut out = Vec::new();
        r.process(&input, &mut out);
        // ~1600 samples at 16k, within a couple of samples of the boundary.
        assert!((out.len() as i64 - 1600).abs() <= 2, "got {}", out.len());
    }

    #[test]
    fn threaded_detector_eventually_reports() {
        let mut d = ThreadedDetector::new(MockDetector::new(16_000, 100, 50));
        // Push past the trigger, then poll for the asynchronous result.
        let mut got = Vec::new();
        for _ in 0..200 {
            got.extend(d.feed(&vec![0.0; 64]));
            if !got.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert_eq!(got.len(), 1);
        assert_eq!(got[0], Detection { start: 100, end: 150 });
    }
}
