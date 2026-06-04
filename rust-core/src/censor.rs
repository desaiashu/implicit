//! Active censor spans and click-free gain/bleep evaluation.
//!
//! Spans are held in *read-head (output) frame* coordinates and applied while
//! the engine copies delayed audio to the output block. Cosine-eased fades on
//! the span edges keep mutes click-free; overlapping spans take the strongest
//! attenuation.

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Mute,
    Bleep,
}

#[derive(Clone, Copy, Debug)]
struct Range {
    start: u64,
    end: u64, // exclusive
}

pub struct Censor {
    mode: Mode,
    fade_frames: u64,
    sample_rate: f32,
    bleep_hz: f32,
    ranges: Vec<Range>,
}

impl Censor {
    pub fn new(mode: Mode, fade_frames: u64, sample_rate: f32) -> Self {
        Self {
            mode,
            fade_frames: fade_frames.max(1),
            sample_rate,
            bleep_hz: 1000.0,
            ranges: Vec::new(),
        }
    }

    pub fn set_mode(&mut self, mode: Mode) {
        self.mode = mode;
    }

    pub fn active(&self) -> usize {
        self.ranges.len()
    }

    /// Register a censor span (output-frame coordinates, half-open).
    pub fn add(&mut self, start: u64, end: u64) {
        if end > start {
            self.ranges.push(Range { start, end });
        }
    }

    /// Drop spans whose trailing fade is fully behind the read head.
    pub fn prune(&mut self, read_frame: u64) {
        let fade = self.fade_frames;
        self.ranges.retain(|r| r.end + fade > read_frame);
    }

    /// Pass-through gain in [0, 1] for an absolute output frame.
    fn gain(&self, frame: u64) -> f32 {
        let f = frame as i64;
        let fade = self.fade_frames as i64;
        let mut g = 1.0f32;
        for r in &self.ranges {
            let (s, e) = (r.start as i64, r.end as i64);
            if f < s - fade || f >= e + fade {
                continue;
            }
            let rg = if f < s {
                // leading fade-out: [s-fade, s) ramps 1 → 0
                1.0 - ease((f - (s - fade)) as f32 / fade as f32)
            } else if f >= e {
                // trailing fade-in: [e, e+fade) ramps 0 → 1
                ease((f - e) as f32 / fade as f32)
            } else {
                0.0
            };
            g = g.min(rg.clamp(0.0, 1.0));
        }
        g
    }

    /// Apply censoring in place to an interleaved output block. `start_frame` is
    /// the absolute output-frame index of the block's first frame.
    pub fn apply(&self, block: &mut [f32], start_frame: u64, channels: usize, frames: usize) {
        for i in 0..frames {
            let frame = start_frame + i as u64;
            let g = self.gain(frame);
            if g >= 1.0 {
                continue;
            }
            let base = i * channels;
            match self.mode {
                Mode::Mute => {
                    for c in 0..channels {
                        block[base + c] *= g;
                    }
                }
                Mode::Bleep => {
                    // Duck the original by `g` and crossfade a tone in by `1-g`,
                    // so the censored region is a clean bleep, not silence.
                    let phase =
                        frame as f32 * self.bleep_hz * std::f32::consts::TAU / self.sample_rate;
                    let tone = phase.sin() * 0.2 * (1.0 - g);
                    for c in 0..channels {
                        block[base + c] = block[base + c] * g + tone;
                    }
                }
            }
        }
    }
}

/// Smooth 0 → 1 cosine ease for click-free ramps.
#[inline]
fn ease(t: f32) -> f32 {
    let t = t.clamp(0.0, 1.0);
    0.5 - 0.5 * (std::f32::consts::PI * t).cos()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gains(c: &Censor, range: std::ops::Range<u64>) -> Vec<f32> {
        range.map(|f| c.gain(f)).collect()
    }

    #[test]
    fn fades_in_and_out_without_discontinuity() {
        let mut c = Censor::new(Mode::Mute, 4, 48_000.0);
        c.add(10, 20);
        let g = gains(&c, 4..26);
        // Fully open before the leading fade and after the trailing fade.
        assert_eq!(g[0], 1.0); // frame 4
        assert_eq!(*g.last().unwrap(), 1.0); // frame 25
        // Fully muted in the core.
        assert_eq!(c.gain(14), 0.0);
        // No step exceeds a gentle slope (click-free).
        for w in g.windows(2) {
            assert!((w[1] - w[0]).abs() <= 0.5, "jump {:?}", w);
        }
        // Leading edge is monotonically non-increasing into the mute.
        for f in 6..10 {
            assert!(c.gain(f) >= c.gain(f + 1));
        }
    }

    #[test]
    fn mute_zeros_core_and_passes_outside() {
        let mut c = Censor::new(Mode::Mute, 2, 48_000.0);
        c.add(100, 110);
        let mut block = vec![1.0f32; 200];
        c.apply(&mut block, 0, 1, 200);
        assert_eq!(block[50], 1.0);
        assert_eq!(block[105], 0.0);
        assert_eq!(block[150], 1.0);
    }

    #[test]
    fn bleep_fills_core_with_tone() {
        let mut c = Censor::new(Mode::Bleep, 2, 48_000.0);
        c.add(100, 140);
        let mut block = vec![0.0f32; 200]; // silent input
        c.apply(&mut block, 0, 1, 200);
        // Core of the span is a non-silent tone even though input was silent.
        let core_energy: f32 = block[110..130].iter().map(|x| x * x).sum();
        assert!(core_energy > 0.0, "bleep should inject a tone");
        assert_eq!(block[10], 0.0); // untouched outside the span
    }

    #[test]
    fn prune_drops_passed_spans() {
        let mut c = Censor::new(Mode::Mute, 4, 48_000.0);
        c.add(10, 20);
        c.add(1000, 1010);
        c.prune(100);
        assert_eq!(c.active(), 1);
    }
}
