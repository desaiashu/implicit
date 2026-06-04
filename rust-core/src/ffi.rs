//! C ABI consumed by the Swift shell. Swift owns the Core Audio process tap and
//! calls [`swear_engine_process`] from its real-time IOProc; everything here is
//! a thin, panic-free wrapper over [`crate::Engine`].
//!
//! The matching header is hand-maintained at `include/swearcore.h`.

use crate::{Config, DetectorTiming, Engine, Mode};
use std::os::raw::c_char;
use std::sync::Arc;

#[repr(C)]
pub struct SwearConfig {
    pub sample_rate: u32,
    pub channels: u32,
    pub delay_ms: f32,
    pub fade_ms: f32,
    /// 0 = mute, 1 = bleep.
    pub mode: u32,
    pub max_block_frames: u32,
    /// Initial detection timing (live-adjustable afterward via the setters).
    pub ms_per_char: u32,
    pub latency_margin_ms: u32,
    pub postroll_ms: u32,
    /// 0.0 = conservative, 1.0 = most sensitive. Set at spotter creation
    /// (changing it requires a fresh engine), maps to threshold + keyword score.
    pub sensitivity: f32,
}

/// Opaque handle owned by Swift. Holds the engine plus the shared, live-tunable
/// detection timing the setters write to (and the detector reads).
pub struct SwearEngine {
    engine: Engine,
    timing: Arc<DetectorTiming>,
}

fn mode_from(raw: u32) -> Mode {
    if raw == 1 {
        Mode::Bleep
    } else {
        Mode::Mute
    }
}

/// Build the detector. With the `sherpa` feature it's the streaming
/// keyword-spotter on its own worker thread; otherwise an inert detector so the
/// pipeline runs as a transparent delay you can drive with `force_censor`.
#[cfg(feature = "sherpa")]
fn make_detector(_device_rate: u32, timing: Arc<DetectorTiming>, sensitivity: f32) -> Box<dyn crate::Detector> {
    crate::kws::default_detector(timing, sensitivity)
}
#[cfg(not(feature = "sherpa"))]
fn make_detector(_device_rate: u32, _timing: Arc<DetectorTiming>, _sensitivity: f32) -> Box<dyn crate::Detector> {
    Box::new(crate::MockDetector::inert(16_000))
}

#[no_mangle]
pub extern "C" fn swear_engine_new(cfg: *const SwearConfig) -> *mut SwearEngine {
    if cfg.is_null() {
        return std::ptr::null_mut();
    }
    let c = unsafe { &*cfg };
    let config = Config {
        sample_rate: c.sample_rate,
        channels: c.channels.max(1) as usize,
        delay_ms: c.delay_ms,
        fade_ms: c.fade_ms,
        mode: mode_from(c.mode),
        max_block_frames: c.max_block_frames.max(1) as usize,
    };
    let timing = Arc::new(DetectorTiming::new(
        c.ms_per_char,
        c.latency_margin_ms,
        c.postroll_ms,
    ));
    let engine = Engine::new(config, make_detector(c.sample_rate, Arc::clone(&timing), c.sensitivity));
    Box::into_raw(Box::new(SwearEngine { engine, timing }))
}

#[no_mangle]
pub extern "C" fn swear_engine_free(p: *mut SwearEngine) {
    if !p.is_null() {
        unsafe { drop(Box::from_raw(p)) };
    }
}

/// Real-time path. `input`/`output` each hold `frames * channels` interleaved
/// f32 samples. Safe to call with equal in/out lengths every IOProc callback.
#[no_mangle]
pub extern "C" fn swear_engine_process(
    p: *mut SwearEngine,
    input: *const f32,
    output: *mut f32,
    frames: u32,
) {
    if p.is_null() || input.is_null() || output.is_null() {
        return;
    }
    let handle = unsafe { &mut *p };
    let n = frames as usize * handle.engine.channels();
    let inp = unsafe { std::slice::from_raw_parts(input, n) };
    let out = unsafe { std::slice::from_raw_parts_mut(output, n) };
    handle.engine.process(inp, out, frames as usize);
}

#[no_mangle]
pub extern "C" fn swear_engine_set_mode(p: *mut SwearEngine, mode: u32) {
    if let Some(handle) = unsafe { p.as_mut() } {
        handle.engine.set_mode(mode_from(mode));
    }
}

/// Live detection-timing setters (UI sliders). They write the shared atomics the
/// worker-thread detector reads on its next hit — no model reload required.
#[no_mangle]
pub extern "C" fn swear_engine_set_ms_per_char(p: *const SwearEngine, ms: u32) {
    if let Some(handle) = unsafe { p.as_ref() } {
        handle.timing.set_ms_per_char(ms);
    }
}

#[no_mangle]
pub extern "C" fn swear_engine_set_latency_margin_ms(p: *const SwearEngine, ms: u32) {
    if let Some(handle) = unsafe { p.as_ref() } {
        handle.timing.set_latency_margin_ms(ms);
    }
}

#[no_mangle]
pub extern "C" fn swear_engine_set_postroll_ms(p: *const SwearEngine, ms: u32) {
    if let Some(handle) = unsafe { p.as_ref() } {
        handle.timing.set_postroll_ms(ms);
    }
}

/// Manually censor `[start_frame, end_frame)` in output-frame coordinates.
#[no_mangle]
pub extern "C" fn swear_engine_force_censor(p: *mut SwearEngine, start_frame: u64, end_frame: u64) {
    if let Some(handle) = unsafe { p.as_mut() } {
        handle.engine.force_censor(start_frame, end_frame);
    }
}

/// Count of currently-active censor spans (for a status indicator).
#[no_mangle]
pub extern "C" fn swear_engine_active_censors(p: *const SwearEngine) -> u32 {
    match unsafe { p.as_ref() } {
        Some(handle) => handle.engine.active_censors() as u32,
        None => 0,
    }
}

/// Static, NUL-terminated version string. Valid for the process lifetime.
#[no_mangle]
pub extern "C" fn swear_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// Tokenise a newline-separated `words` list with the model's BPE (under
/// `model_dir`) and write the sherpa keyword file to `out_path`. Lets the app
/// add/edit words without Python. Returns the number of keywords written, or -1
/// on error. The engine must be recreated afterward to load the new file.
#[cfg(feature = "sherpa")]
#[no_mangle]
pub extern "C" fn swear_tokenize_keywords(
    model_dir: *const c_char,
    words: *const c_char,
    out_path: *const c_char,
) -> i32 {
    use std::ffi::CStr;
    if model_dir.is_null() || words.is_null() || out_path.is_null() {
        return -1;
    }
    let cstr = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    let dir = cstr(model_dir);
    let list: Vec<String> = cstr(words).lines().map(str::to_owned).collect();
    let out = cstr(out_path);

    match crate::tokenize::keywords_file_contents(std::path::Path::new(&dir), &list) {
        Ok(contents) => {
            let count = contents.lines().count() as i32;
            match std::fs::write(&out, contents) {
                Ok(()) => count,
                Err(_) => -1,
            }
        }
        Err(e) => {
            eprintln!("[swearcore] tokenize failed: {e}");
            -1
        }
    }
}
