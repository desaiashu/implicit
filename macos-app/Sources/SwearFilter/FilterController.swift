import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI

/// Owns the audio tap and the live-tunable settings, and bridges them to the
/// menubar UI. Live params (mute/bleep, word-length estimate, latency reach-back,
/// postroll) are pushed straight into the running engine; the output delay is
/// structural (fixes the buffer size) so it rebuilds the engine on change.
@MainActor
final class FilterController: ObservableObject {
    @Published private(set) var isOn = false
    @Published var statusMessage: String?

    @Published var bleep: Bool {
        didSet { tap?.setMode(bleep ? .bleep : .mute); defaults.set(bleep, forKey: Key.bleep) }
    }
    /// Output latency / max reach-back, ms. Applied by rebuilding the engine.
    @Published var delayMs: Double {
        didSet { defaults.set(delayMs, forKey: Key.delay) }
    }
    /// 0...1 detection sensitivity. Set at spotter creation, so rebuilds on change.
    @Published var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: Key.sensitivity) }
    }
    @Published var msPerChar: Double {
        didSet { tap?.setMsPerChar(UInt32(msPerChar)); defaults.set(msPerChar, forKey: Key.msPerChar) }
    }
    @Published var latencyMarginMs: Double {
        didSet { tap?.setLatencyMargin(UInt32(latencyMarginMs)); defaults.set(latencyMarginMs, forKey: Key.latency) }
    }
    @Published var postrollMs: Double {
        didSet { tap?.setPostroll(UInt32(postrollMs)); defaults.set(postrollMs, forKey: Key.postroll) }
    }

    private var tap: AudioTap?
    private let defaults = UserDefaults.standard
    private enum Key {
        static let bleep = "bleep", delay = "delayMs", msPerChar = "msPerChar"
        static let latency = "latencyMarginMs", postroll = "postrollMs", sensitivity = "sensitivity"
    }

    /// Factory defaults, shared by first launch and the Reset button.
    enum Defaults {
        static let bleep = false, delay = 800.0, msPerChar = 80.0
        static let latency = 350.0, postroll = 150.0, sensitivity = 0.7
    }

    init() {
        // Point the engine at the model bundled under Resources/models.
        if let res = Bundle.main.resourcePath {
            setenv("SWEAR_KWS_DIR", "\(res)/models", 1)
        }
        // Restore saved settings (didSet does not fire during init). Use a local
        // UserDefaults handle so we don't touch `self` before init completes.
        let ud = UserDefaults.standard
        func saved(_ key: String, _ fallback: Double) -> Double {
            ud.object(forKey: key) == nil ? fallback : ud.double(forKey: key)
        }
        bleep = ud.object(forKey: Key.bleep) == nil ? Defaults.bleep : ud.bool(forKey: Key.bleep)
        delayMs = saved(Key.delay, Defaults.delay)
        msPerChar = saved(Key.msPerChar, Defaults.msPerChar)
        latencyMarginMs = saved(Key.latency, Defaults.latency)
        postrollMs = saved(Key.postroll, Defaults.postroll)
        sensitivity = saved(Key.sensitivity, Defaults.sensitivity)

        requestPermissions()
    }

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard tap == nil else { return }
        let t = AudioTap(delayMs: Float(delayMs),
                         mode: bleep ? .bleep : .mute,
                         msPerChar: UInt32(msPerChar),
                         latencyMarginMs: UInt32(latencyMarginMs),
                         postrollMs: UInt32(postrollMs),
                         sensitivity: Float(sensitivity))
        do {
            try t.start()
            tap = t
            isOn = true
            statusMessage = CGPreflightScreenCaptureAccess()
                ? nil
                : "Allow Screen & System Audio Recording in System Settings, then toggle on again."
        } catch {
            statusMessage = "Couldn't start: \(error)"
            isOn = false
        }
    }

    func stop() {
        tap?.stop()
        tap = nil
        isOn = false
    }

    /// Delay (buffer size) and sensitivity (spotter config) are baked in at
    /// engine creation, so changing them needs a fresh engine. Called on slider
    /// release only, to avoid reloading the model mid-drag.
    func restartForStructuralChange() {
        guard isOn else { return }
        stop()
        start()
    }

    /// Restore every setting to its factory default.
    func reset() {
        bleep = Defaults.bleep
        msPerChar = Defaults.msPerChar
        latencyMarginMs = Defaults.latency
        postrollMs = Defaults.postroll
        delayMs = Defaults.delay
        sensitivity = Defaults.sensitivity
        restartForStructuralChange()
    }

    /// Prompt for the two permissions a process tap needs: microphone and (on
    /// macOS 15+/26) Screen & System Audio Recording. Both are no-ops once granted.
    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}
