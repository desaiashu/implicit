import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI

/// Owns the audio tap and the live-tunable settings, and bridges them to the
/// menubar UI. The detector is Whisper (transcribe + match words in the
/// transcript), so the word list is plain text — edits take effect on the next
/// engine start with no tokenisation step.
@MainActor
final class FilterController: ObservableObject {
    @Published private(set) var isOn = false
    @Published var statusMessage: String?

    @Published var bleep: Bool {
        didSet { tap?.setMode(bleep ? .bleep : .mute); defaults.set(bleep, forKey: Key.bleep) }
    }
    /// Output latency, ms. Must exceed Whisper's recognition lag — applied by
    /// rebuilding the engine (it sizes the delay buffer).
    @Published var delayMs: Double {
        didSet { defaults.set(delayMs, forKey: Key.delay) }
    }
    /// Extra silence kept after a censored word, ms (live).
    @Published var postrollMs: Double {
        didSet { tap?.setPostroll(UInt32(postrollMs)); defaults.set(postrollMs, forKey: Key.postroll) }
    }

    /// Editable word list, one word per line (what the editor window binds to).
    @Published var wordsText: String
    @Published var wordsStatus: String?
    /// Set by the AppDelegate so the menu's "Edit Words…" button can open the window.
    var openEditor: (() -> Void)?

    private var tap: AudioTap?
    private let defaults = UserDefaults.standard
    private let wordsURL: URL // writable plain word list the detector reads

    private enum Key {
        static let bleep = "bleep", delay = "delayMs", postroll = "postrollMs"
    }

    /// Factory defaults, shared by first launch and the Reset button.
    enum Defaults {
        static let bleep = false
        static let delay = 2500.0  // Whisper runs in rolling windows → larger lag than the old spotter
        static let postroll = 150.0
    }

    init() {
        let res = Bundle.main.resourcePath ?? ""

        // Writable word list in Application Support, seeded from the bundled
        // default list on first run.
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Implicit", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        wordsURL = dir.appendingPathComponent("words.txt")
        if !fm.fileExists(atPath: wordsURL.path) {
            let seed = URL(fileURLWithPath: "\(res)/swears.txt")
            try? fm.copyItem(at: seed, to: wordsURL)
        }
        wordsText = (try? String(contentsOf: wordsURL, encoding: .utf8)) ?? ""

        // Engine env: the bundled whisper model + the writable word list.
        setenv("SWEAR_WHISPER_MODEL", "\(res)/ggml-small.en.bin", 1)
        setenv("SWEAR_WORDS_FILE", wordsURL.path, 1)

        // Restore saved settings (didSet does not fire during init).
        let ud = UserDefaults.standard
        func saved(_ key: String, _ fallback: Double) -> Double {
            ud.object(forKey: key) == nil ? fallback : ud.double(forKey: key)
        }
        bleep = ud.object(forKey: Key.bleep) == nil ? Defaults.bleep : ud.bool(forKey: Key.bleep)
        delayMs = saved(Key.delay, Defaults.delay)
        postrollMs = saved(Key.postroll, Defaults.postroll)

        requestPermissions()
    }

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard tap == nil else { return }
        let t = AudioTap(delayMs: Float(delayMs),
                         mode: bleep ? .bleep : .mute,
                         postrollMs: UInt32(postrollMs))
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

    /// The delay sizes the buffer (fixed at engine creation), so a change needs a
    /// fresh engine. Called on slider release only.
    func restartForStructuralChange() {
        guard isOn else { return }
        stop()
        start()
    }

    func reset() {
        bleep = Defaults.bleep
        postrollMs = Defaults.postroll
        delayMs = Defaults.delay
        restartForStructuralChange()
    }

    /// Save the edited word list and reload the engine (if running) so it picks
    /// up the new words. No tokenisation — Whisper matches plain text.
    func applyWords() {
        do {
            try wordsText.write(to: wordsURL, atomically: true, encoding: .utf8)
        } catch {
            wordsStatus = "Couldn't save the list: \(error.localizedDescription)"
            return
        }
        let count = wordsText.split(whereSeparator: \.isNewline)
            .filter { let t = $0.trimmingCharacters(in: .whitespaces); return !t.isEmpty && !t.hasPrefix("#") }
            .count
        wordsStatus = "\(count) words — reloading…"
        restartForStructuralChange()
        wordsStatus = "\(count) words active."
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
