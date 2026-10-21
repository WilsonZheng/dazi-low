import AVFoundation
import CoreAudio

/// Captures the microphone as 16 kHz mono Float32 chunks.
///
/// Prefers the built-in microphone: opening a Bluetooth headset's mic switches it to
/// its low-quality call profile and restarts the audio engine mid-recording.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// Called on the audio thread with each converted chunk.
    var onChunk: (([Float]) -> Void)?
    /// RMS level of the latest chunk, 0...1, for the HUD.
    private(set) var level: Float = 0
    private(set) var isRunning = false
    private(set) var restarts = 0

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var configObserver: NSObjectProtocol?

    /// Test hook: DAZI_FAKE_MIC=/path/file.wav plays that file as the microphone, in real
    /// time, so the whole live path (hotkey, HUD, engine, paste) can be tested end to end.
    private let fakeMic = ProcessInfo.processInfo.environment["DAZI_FAKE_MIC"]
    private var fakeTimer: DispatchSourceTimer?

    /// The first audio engine in a process takes ~3 s to come up (Core Audio client
    /// setup), which swallowed the start of the first dictation after launch. Doing the
    /// setup at launch, without starting capture, leaves the mic indicator off.
    func prewarm() {
        let t = Date()
        let e = AVAudioEngine()
        if let mic = Self.builtInMicrophone(), let unit = e.inputNode.audioUnit {
            var id = mic
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        _ = e.inputNode.outputFormat(forBus: 0)
        e.prepare()
        AppLog.write(String(format: "audio prewarmed in %.2f s", Date().timeIntervalSince(t)))
    }

    func start() throws {
        guard !isRunning else { return }
        restarts = 0
        if let path = fakeMic {
            let samples = try SelfTest.loadMono16k(path)
            var pos = 0
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dazi.fakemic"))
            t.schedule(deadline: .now(), repeating: .milliseconds(100))
            t.setEventHandler { [weak self] in
                let end = min(pos + 1600, samples.count)
                let chunk = pos < end ? Array(samples[pos..<end]) : [Float](repeating: 0, count: 1600)
                pos = end
                self?.emit(chunk)
            }
            fakeTimer = t
            t.resume()
            isRunning = true
            return
        }
        // A fresh engine every time: a reused one can hold a stale input format after a
        // device change, and installTap then raises an Objective-C exception.
        let t0 = Date()
        engine = AVAudioEngine()
        let mic = Self.builtInMicrophone()
        let t1 = Date()
        if let mic, let unit = engine.inputNode.audioUnit {
            var id = mic
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let t2 = Date()
        try tapAndStart()
        AppLog.write(String(format: "mic started in %.2f s (find device %.2f, select %.2f, start %.2f): %@",
                            Date().timeIntervalSince(t0), t1.timeIntervalSince(t0), t2.timeIntervalSince(t1),
                            Date().timeIntervalSince(t2), "\(engine.inputNode.outputFormat(forBus: 0))"))
        isRunning = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    func stop() {
        guard isRunning else { return }
        if let t = fakeTimer {
            t.cancel()
            fakeTimer = nil
            isRunning = false
            return
        }
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = 0
    }

    private func tapAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "DaziLow", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风"])
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// The engine stops itself when the input hardware changes (including right after we
    /// pick the built-in mic). Re-tap with the new format on the same engine and device;
    /// never re-select the device here, which would trigger another change.
    private func handleConfigurationChange() {
        AppLog.write("audio configuration changed (engine running: \(engine.isRunning), restarts \(restarts))")
        guard isRunning, !engine.isRunning, restarts < 3 else { return }
        restarts += 1
        engine.inputNode.removeTap(onBus: 0)
        do {
            try tapAndStart()
        } catch {
            NSLog("DaziLow: audio restart failed: \(error)")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        emit(samples)
    }

    private func emit(_ samples: [Float]) {
        var sum: Float = 0
        for s in samples { sum += s * s }
        // Decibel scale: this microphone records quietly (speech peaks near RMS 0.02),
        // so a linear level would barely move. -52 dB -> 0, -24 dB -> 1.
        let db = 20 * log10(max(sqrt(sum / Float(max(samples.count, 1))), 1e-6))
        level = max(0, min(1, (db + 52) / 28))
        onChunk?(samples)
    }

    /// The first built-in device that has input channels, if any.
    static func builtInMicrophone() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioDevicePropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize) == noErr, ssize > 0 {
                return id
            }
        }
        return nil
    }
}
