import CSwearCore
import Foundation

/// Thin, safe Swift wrapper over the swearcore C ABI.
///
/// `process` is called from the real-time audio IOProc; it does no allocation
/// on the Swift side and forwards straight to Rust.
final class RustCore {
    enum Mode: UInt32 { case mute = 0, bleep = 1 }

    private let handle: OpaquePointer
    let channels: Int

    init?(sampleRate: Double, channels: Int, delayMs: Float, fadeMs: Float, mode: Mode,
          msPerChar: UInt32, latencyMarginMs: UInt32, postrollMs: UInt32, sensitivity: Float) {
        var cfg = SwearConfig(
            sample_rate: UInt32(sampleRate),
            channels: UInt32(channels),
            delay_ms: delayMs,
            fade_ms: fadeMs,
            mode: mode.rawValue,
            max_block_frames: 8192,
            ms_per_char: msPerChar,
            latency_margin_ms: latencyMarginMs,
            postroll_ms: postrollMs,
            sensitivity: sensitivity
        )
        guard let h = swear_engine_new(&cfg) else { return nil }
        self.handle = h
        self.channels = channels
    }

    deinit { swear_engine_free(handle) }

    /// Interleaved f32 in → censored, delayed interleaved f32 out. Real-time safe.
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: UInt32) {
        swear_engine_process(handle, input, output, frames)
    }

    func setMode(_ mode: Mode) { swear_engine_set_mode(handle, mode.rawValue) }
    // Live detection-timing setters (no model reload).
    func setMsPerChar(_ ms: UInt32) { swear_engine_set_ms_per_char(handle, ms) }
    func setLatencyMargin(_ ms: UInt32) { swear_engine_set_latency_margin_ms(handle, ms) }
    func setPostroll(_ ms: UInt32) { swear_engine_set_postroll_ms(handle, ms) }

    func activeCensors() -> UInt32 { swear_engine_active_censors(handle) }

    static var version: String {
        String(cString: swear_core_version())
    }

    /// Tokenise a newline-separated word list with the model's BPE and write the
    /// sherpa keyword file. Returns the number of keywords written, or -1 on error.
    /// Doesn't need an engine instance.
    @discardableResult
    static func tokenizeKeywords(modelDir: String, words: String, outPath: String) -> Int32 {
        swear_tokenize_keywords(modelDir, words, outPath)
    }
}
