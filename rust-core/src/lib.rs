//! swearcore — real-time speech censor pipeline.
//!
//! Audio flows: device input → [`Engine::process`] → delayed, censored output.
//! The engine runs a fixed delay line (the broadcast-style "dump" buffer) and,
//! in parallel, feeds a downmixed/resampled copy to a keyword-spotting
//! [`Detector`]. When a target word is recognised, its span is censored in the
//! still-buffered (not-yet-played) audio before it reaches the speakers.
//!
//! The spotter fires when a word *completes*, and only after its own latency
//! (~160–320 ms). To censor the whole word the detector reaches back by the
//! word's *measured* length (from the spotter's token timestamps) plus a latency
//! margin — so the censored span tracks each word instead of a flat worst-case
//! window. The censor edits the still-buffered (not-yet-played) audio, so the
//! delay line must be at least as long as that reach-back; whatever doesn't fit
//! in `delay_ms` (e.g. the start of an unusually long word) leaks through. Hence
//! a sub-second delay works for most words, but the floor is fundamentally
//! `word_duration + detector_latency` — you can't censor a word before you know
//! it's a swear, which isn't until it has finished being said.

mod censor;
mod delay;
mod detector;
pub mod ffi;
#[cfg(feature = "sherpa")]
mod kws;
#[cfg(feature = "sherpa")]
pub mod tokenize;

pub use censor::Mode;
pub use detector::{Detection, Detector, DetectorTiming, MockDetector, ThreadedDetector};

use censor::Censor;
use delay::DelayBuffer;
use detector::{downmix, LinearResampler};

pub struct Config {
    pub sample_rate: u32,
    pub channels: usize,
    pub delay_ms: f32,
    pub fade_ms: f32,
    pub mode: Mode,
    pub max_block_frames: usize,
}

pub struct Engine {
    channels: usize,
    delay_frames: u64,
    det_to_dev: f64, // device_rate / detector_rate
    delay: DelayBuffer,
    censor: Censor,
    detector: Box<dyn Detector>,
    resampler: LinearResampler,
    mono: Vec<f32>,
    resampled: Vec<f32>,
}

impl Engine {
    pub fn new(cfg: Config, detector: Box<dyn Detector>) -> Self {
        let channels = cfg.channels.max(1);
        let delay_frames = ((cfg.delay_ms / 1000.0) * cfg.sample_rate as f32).round() as u64;
        let fade_frames = ((cfg.fade_ms / 1000.0) * cfg.sample_rate as f32).round().max(1.0) as u64;
        let det_rate = detector.sample_rate();
        Self {
            channels,
            delay_frames,
            det_to_dev: cfg.sample_rate as f64 / det_rate as f64,
            delay: DelayBuffer::new(channels, delay_frames as usize, cfg.max_block_frames.max(1)),
            censor: Censor::new(cfg.mode, fade_frames, cfg.sample_rate as f32),
            resampler: LinearResampler::new(cfg.sample_rate, det_rate),
            detector,
            mono: Vec::new(),
            resampled: Vec::new(),
        }
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    pub fn set_mode(&mut self, mode: Mode) {
        self.censor.set_mode(mode);
    }

    pub fn active_censors(&self) -> usize {
        self.censor.active()
    }

    /// Manually censor a span, in output-frame coordinates (testing / a "bleep
    /// the last few seconds" panic button driven from the UI).
    pub fn force_censor(&mut self, start_frame: u64, end_frame: u64) {
        self.censor.add(start_frame, end_frame);
    }

    /// Process one interleaved block; `input`/`output` are `frames * channels`.
    pub fn process(&mut self, input: &[f32], output: &mut [f32], frames: usize) {
        // 1. Feed the detector a mono, detector-rate copy.
        downmix(input, self.channels, &mut self.mono);
        self.resampled.clear();
        self.resampler.process(&self.mono, &mut self.resampled);
        for det in self.detector.feed(&self.resampled) {
            // detector-rate frames → device frames → output (read) coordinates.
            let start = (det.start as f64 * self.det_to_dev) as u64 + self.delay_frames;
            let end = (det.end as f64 * self.det_to_dev) as u64 + self.delay_frames;
            self.censor.add(start, end);
        }

        // 2. Delay the raw audio, then censor on the delayed timeline.
        self.delay.write(input, frames);
        let start_frame = self.delay.read(output, frames);
        self.censor.apply(output, start_frame, self.channels, frames);
        self.censor.prune(self.delay.read_frame());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(engine: &mut Engine, samples: usize, block: usize) -> Vec<f32> {
        // Constant 1.0 mono signal so it's obvious where censoring bites.
        let mut out_all = Vec::with_capacity(samples);
        let mut produced = 0;
        let mut buf = vec![0.0f32; block];
        while produced < samples {
            let n = block.min(samples - produced);
            let input = vec![1.0f32; n];
            engine.process(&input, &mut buf[..n], n);
            out_all.extend_from_slice(&buf[..n]);
            produced += n;
        }
        out_all
    }

    #[test]
    fn transparent_delay_when_detector_silent() {
        let cfg = Config {
            sample_rate: 16_000,
            channels: 1,
            delay_ms: 100.0, // 1600 frames
            fade_ms: 5.0,
            mode: Mode::Mute,
            max_block_frames: 512,
        };
        let mut e = Engine::new(cfg, Box::new(MockDetector::inert(16_000)));
        let out = run(&mut e, 8000, 512);
        // First 1600 frames are the primed delay (silence)…
        assert!(out[..1600].iter().all(|&x| x == 0.0));
        // …then a clean pass-through of the constant signal.
        assert!(out[2000..].iter().all(|&x| (x - 1.0).abs() < 1e-6));
    }

    #[test]
    fn censors_detected_span_on_delayed_timeline() {
        let cfg = Config {
            sample_rate: 16_000,
            channels: 1,
            delay_ms: 200.0, // 3200 frames — comfortably > mock latency (~0)
            fade_ms: 5.0,    // 80 frames
            mode: Mode::Mute,
            max_block_frames: 256,
        };
        // Fire a 1600-frame (0.1s) span starting at input frame 8000.
        let det = MockDetector::new(16_000, 8000, 1600);
        let mut e = Engine::new(cfg, Box::new(det));
        let out = run(&mut e, 20_000, 256);

        // Input frame 8000 is read out at 8000 + delay(3200) = 11200.
        let core = 11_200 + 800; // middle of the muted span
        assert!(out[core].abs() < 1e-3, "span core should be muted: {}", out[core]);
        // Well clear of the span (and past the initial delay) it passes through.
        assert!((out[6000] - 1.0).abs() < 1e-6);
        assert!((out[15_000] - 1.0).abs() < 1e-6);
        // Edges ramp rather than jump — no sample-to-sample step near 1.0.
        for w in out[11_000..11_300].windows(2) {
            assert!((w[1] - w[0]).abs() < 0.2, "click at mute edge: {:?}", w);
        }
    }
}
