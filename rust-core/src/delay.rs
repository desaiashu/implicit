//! Fixed-latency interleaved delay ring buffer.
//!
//! Stores *raw* audio only. Censoring is applied on read by the engine, never
//! baked into the buffer, so a censor span that straddles several process
//! blocks stays idempotent (applying it twice can't double-attenuate).

pub struct DelayBuffer {
    channels: usize,
    capacity_frames: usize,
    buf: Vec<f32>,
    /// Absolute frame index of the next frame to be written.
    write_frame: u64,
    /// Absolute frame index of the next frame to be read.
    read_frame: u64,
}

impl DelayBuffer {
    pub fn new(channels: usize, delay_frames: usize, max_block_frames: usize) -> Self {
        let channels = channels.max(1);
        // The write head leads the read head by exactly `delay_frames`; one
        // extra block of headroom covers the in-flight write within a block.
        let capacity_frames = (delay_frames + max_block_frames + 1).next_power_of_two();
        Self {
            channels,
            capacity_frames,
            buf: vec![0.0; capacity_frames * channels],
            // Seed the delay: the first `delay_frames` reads land on
            // zero-initialised slots and emit silence.
            write_frame: delay_frames as u64,
            read_frame: 0,
        }
    }

    /// Absolute frame index the read head currently points at.
    pub fn read_frame(&self) -> u64 {
        self.read_frame
    }

    #[inline]
    fn phys(&self, frame: u64) -> usize {
        (frame as usize % self.capacity_frames) * self.channels
    }

    /// Write one interleaved block (`frames * channels` samples); advances write.
    pub fn write(&mut self, input: &[f32], frames: usize) {
        let ch = self.channels;
        for f in 0..frames {
            let dst = self.phys(self.write_frame);
            let src = f * ch;
            self.buf[dst..dst + ch].copy_from_slice(&input[src..src + ch]);
            self.write_frame += 1;
        }
    }

    /// Read one interleaved block of raw audio; advances read. Returns the
    /// absolute frame index of the first frame read (the censor coordinate).
    pub fn read(&mut self, out: &mut [f32], frames: usize) -> u64 {
        let ch = self.channels;
        let start = self.read_frame;
        for f in 0..frames {
            let dst = f * ch;
            if self.read_frame < self.write_frame {
                let src = self.phys(self.read_frame);
                out[dst..dst + ch].copy_from_slice(&self.buf[src..src + ch]);
            } else {
                out[dst..dst + ch].fill(0.0); // underflow → silence
            }
            self.read_frame += 1;
        }
        start
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emits_delay_then_signal() {
        let delay = 4;
        let mut d = DelayBuffer::new(1, delay, 8);
        let input: Vec<f32> = (1..=8).map(|n| n as f32).collect();
        let mut out = vec![0.0; 8];
        d.write(&input, 8);
        let start = d.read(&mut out, 8);
        assert_eq!(start, 0);
        // First `delay` frames are silence, then the input shifted right.
        assert_eq!(out, vec![0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0]);
    }

    #[test]
    fn stereo_interleaving_preserved() {
        let mut d = DelayBuffer::new(2, 0, 4);
        let input = vec![1.0, -1.0, 2.0, -2.0]; // 2 frames, L/R
        let mut out = vec![0.0; 4];
        d.write(&input, 2);
        d.read(&mut out, 2);
        assert_eq!(out, input);
    }
}
