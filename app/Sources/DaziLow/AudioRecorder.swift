import AVFoundation

/// Captures the default microphone as 16 kHz mono Float32 chunks.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// Called on the audio thread with each converted chunk.
    var onChunk: (([Float]) -> Void)?
    /// RMS level of the latest chunk, 0...1, for the HUD.
    private(set) var level: Float = 0

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var configObserver: NSObjectProtocol?
    private(set) var isRunning = false

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            // Input device changed (headset plugged in, etc.): rebuild next time.
            guard let self, !self.isRunning else { return }
            self.engine = AVAudioEngine()
        }
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "DaziLow", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风"])
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 1600, format: inFormat) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = 0
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
        var sum: Float = 0
        for s in samples { sum += s * s }
        level = min(1, sqrt(sum / Float(samples.count)) * 6)
        onChunk?(samples)
    }
}
