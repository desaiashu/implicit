import AVFoundation
import AppKit
import CoreGraphics
import SwiftUI

/// Owns the audio tap and the live-tunable settings, and bridges them to the
/// menubar UI. Live params (mute/bleep, word-length estimate, latency reach-back,
/// postroll) are pushed straight into the running engine; the output delay and
/// sensitivity are structural (baked in at engine creation) so they rebuild the
/// engine on change. The editable word list is tokenised on apply and written to
/// a writable keyword file outside the (read-only, signed) app bundle.
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

    /// Editable word list, one word per line (what the editor window binds to).
    @Published var wordsText: String
    @Published var wordsStatus: String?
    /// Set by the AppDelegate so the menu's "Edit Words…" button can open the window.
    var openEditor: (() -> Void)?

    private var tap: AudioTap?
    private let defaults = UserDefaults.standard
    private let modelDir: String     // read-only, bundled (encoder/decoder/bpe/tokens)
    private let keywordsURL: URL     // writable, tokenised keyword file the engine loads
    private let wordsURL: URL        // writable, the human-readable word list

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
        let bundleModels = Bundle.main.resourcePath.map { "\($0)/models" } ?? ""
        modelDir = bundleModels

        // Writable copies of the keyword files live in Application Support, so the
        // editor never has to touch the signed app bundle.
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Implicit", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        keywordsURL = dir.appendingPathComponent("keywords.txt")
        wordsURL = dir.appendingPathComponent("words.txt")

        // Seed the tokenised keyword file from the bundle on first run so detection
        // works before any edit.
        let bundledKeywords = URL(fileURLWithPath: "\(bundleModels)/keywords.txt")
        if !fm.fileExists(atPath: keywordsURL.path), fm.fileExists(atPath: bundledKeywords.path) {
            try? fm.copyItem(at: bundledKeywords, to: keywordsURL)
        }
        // Editable word list: restore the saved one, else derive from the @labels
        // in the keyword file.
        if let saved = try? String(contentsOf: wordsURL, encoding: .utf8), !saved.isEmpty {
            wordsText = saved
        } else {
            let seed = fm.fileExists(atPath: keywordsURL.path) ? keywordsURL : bundledKeywords
            wordsText = Self.wordsFromKeywordFile(seed)
        }

        // Engine env: model dir (read-only) + the writable keyword file.
        setenv("SWEAR_KWS_DIR", modelDir, 1)
        setenv("SWEAR_KEYWORDS_FILE", keywordsURL.path, 1)

        // Restore saved settings (didSet does not fire during init).
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

    /// Tokenise the edited word list into the writable keyword file and reload
    /// the engine (if running) so it takes effect.
    func applyWords() {
        try? wordsText.write(to: wordsURL, atomically: true, encoding: .utf8)
        let written = RustCore.tokenizeKeywords(modelDir: modelDir, words: wordsText, outPath: keywordsURL.path)
        guard written >= 0 else {
            wordsStatus = "Couldn't tokenize the list — check the words."
            return
        }
        let dropped = wordsText.split(whereSeparator: \.isNewline)
            .filter { let t = $0.trimmingCharacters(in: .whitespaces); return !t.isEmpty && !t.hasPrefix("#") }
            .count - Int(written)
        wordsStatus = dropped > 0
            ? "\(written) words active (\(dropped) couldn't be tokenized)."
            : "\(written) words active."
        if isOn { restartForStructuralChange() }
    }

    /// Extract the human-readable words (the `@word` suffix) from a keyword file.
    private static func wordsFromKeywordFile(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        var words: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let at = line.lastIndex(of: "@") else { continue }
            let word = line[line.index(after: at)...].trimmingCharacters(in: .whitespaces)
            if !word.isEmpty { words.append(word) }
        }
        return words.joined(separator: "\n")
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
