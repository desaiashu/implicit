import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures system audio via a Core Audio process tap (macOS 14.4+), runs it
/// through the Rust censor, and plays the result to the current output device.
///
/// Pipeline: [all processes except us] --(muted tap)--> aggregate device IOProc
///           --> RustCore.process --> aggregate's output sub-device (speakers).
///
/// The tap is *muted* so the OS doesn't also play the original — only our
/// delayed, censored copy reaches the speakers. Our own process is excluded
/// from the tap so our playback isn't recaptured into a feedback loop.
///
/// Output-device tracking: we listen for default-output-device changes and
/// rebuild the aggregate around the new device, so switching to AirPods / HDMI /
/// speakers mid-stream keeps working. The tap and the Rust core stay put across
/// a switch.
final class AudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var core: RustCore?
    private var tapUUID = ""

    private let listenerQueue = DispatchQueue(label: "com.swearfilter.device-listener")
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    let delayMs: Float
    let fadeMs: Float
    let mode: RustCore.Mode
    let msPerChar: UInt32
    let latencyMarginMs: UInt32
    let postrollMs: UInt32
    let sensitivity: Float

    init(delayMs: Float = 800, fadeMs: Float = 6, mode: RustCore.Mode = .mute,
         msPerChar: UInt32 = 80, latencyMarginMs: UInt32 = 350, postrollMs: UInt32 = 150,
         sensitivity: Float = 0.7) {
        self.delayMs = delayMs
        self.fadeMs = fadeMs
        self.mode = mode
        self.msPerChar = msPerChar
        self.latencyMarginMs = latencyMarginMs
        self.postrollMs = postrollMs
        self.sensitivity = sensitivity
    }

    func start() throws {
        // Tap every running audio process except ourselves (excluding self keeps
        // our own censored playback out of the tap — no feedback loop). We
        // enumerate the process objects and use `stereoMixdownOfProcesses`; the
        // `stereoGlobalTapButExcludeProcesses` initializer produces a tap that
        // never delivers audio. Matches Apple's tap sample / AudioCap.
        let selfObj = Self.processObject(for: getpid())
        let targets = Self.allProcessObjects().filter { $0 != selfObj }
        let description = CATapDescription(stereoMixdownOfProcesses: targets)
        description.name = "SwearFilter Tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        tapUUID = description.uuid.uuidString

        try check(AudioHardwareCreateProcessTap(description, &tapID),
                  "AudioHardwareCreateProcessTap")

        // Read the tap's stream format → RustCore config.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd),
                  "get kAudioTapPropertyFormat")

        guard let core = RustCore(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame),
                                  delayMs: delayMs, fadeMs: fadeMs, mode: mode,
                                  msPerChar: msPerChar, latencyMarginMs: latencyMarginMs,
                                  postrollMs: postrollMs, sensitivity: sensitivity) else {
            throw TapError("RustCore init failed")
        }
        self.core = core

        // Build the output graph, then track output-device changes.
        try rebuildOutput()
        installDefaultOutputListener()
    }

    /// Translate a pid into the Core Audio process object ID, or nil if the
    /// process has no audio object (HAL returns kAudioObjectUnknown).
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pidValue = pid
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &objectID)
        return (status == noErr && objectID != kAudioObjectUnknown) ? objectID : nil
    }

    /// Every audio process object currently known to the HAL.
    private static func allProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    func stop() {
        if let block = defaultOutputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddr, listenerQueue, block)
            defaultOutputListener = nil
        }
        teardownOutput()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        core = nil
    }

    func setMode(_ mode: RustCore.Mode) { core?.setMode(mode) }
    func setMsPerChar(_ ms: UInt32) { core?.setMsPerChar(ms) }
    func setLatencyMargin(_ ms: UInt32) { core?.setLatencyMargin(ms) }
    func setPostroll(_ ms: UInt32) { core?.setPostroll(ms) }

    // MARK: - Output graph (rebuilt on device change)

    /// (Re)create the aggregate device + IOProc around the current default
    /// output device. Reuses the existing tap and core.
    private func rebuildOutput() throws {
        teardownOutput()

        let outputUID = try defaultOutputDeviceUID()
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SwearFilter",
            // Unique per aggregate so a leaked instance (crash / unclean exit)
            // never blocks the next launch with a duplicate-UID error.
            kAudioAggregateDeviceUIDKey as String: "com.swearfilter.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            // Without this the tap is in the aggregate but never starts feeding
            // audio into the IOProc — the input stream stays silent.
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outputUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: tapUUID,
                kAudioSubTapDriftCompensationKey as String: true
            ]]
        ]
        try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inInput, _, outOutput, _ in
            self?.render(input: inInput, output: outOutput)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
    }

    private func teardownOutput() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
    }

    private func installDefaultOutputListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            do { try self.rebuildOutput() }
            catch { FileHandle.standardError.write(Data("output switch failed: \(error)\n".utf8)) }
        }
        defaultOutputListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddr, listenerQueue, block)
    }

    // MARK: - Real-time render

    /// The aggregate's IOProc: tap audio arrives interleaved on the first input
    /// buffer, censored output goes to the first output buffer (verified stereo
    /// interleaved on real devices).
    private func render(input: UnsafePointer<AudioBufferList>,
                        output: UnsafeMutablePointer<AudioBufferList>) {
        guard let core else { return }
        let inBuf = input.pointee.mBuffers
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard let inData = inBuf.mData, var outBuf = outList.first, let outData = outBuf.mData
        else { return }

        let frames = Int(inBuf.mDataByteSize) / (MemoryLayout<Float>.size * core.channels)
        core.process(input: inData.assumingMemoryBound(to: Float.self),
                     output: outData.assumingMemoryBound(to: Float.self),
                     frames: UInt32(frames))
        outBuf.mDataByteSize = inBuf.mDataByteSize
    }

    // MARK: - Helpers

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &defaultOutputAddr, 0, nil, &size, &deviceID),
                  "get DefaultOutputDevice")

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid), "get DeviceUID")
        return uid as String
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError("\(what) failed: OSStatus \(status)") }
    }
}

struct TapError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
