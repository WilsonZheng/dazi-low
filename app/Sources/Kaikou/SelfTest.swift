import AVFoundation
import Foundation

/// `Kaikou --transcribe file.wav [...]`: runs audio files through the same engine
/// client the app uses and prints one JSON result per file. Needs no permissions,
/// so the whole app-to-engine path can be tested headlessly. `--realtime` streams
/// the audio at speaking pace, so background recognition overlaps as it does live.
enum SelfTest {
    static func run(files: [String], realtime: Bool = false) -> Int32 {
        Paths.ensure()
        let engineProcess = EngineProcess()
        let client = EngineClient(socketPath: Paths.socket)
        let lock = NSCondition()
        var inbox: [[String: Any]] = []
        client.onMessage = { msg in lock.lock(); inbox.append(msg); lock.signal(); lock.unlock() }

        func waitFor(_ deadline: Date, _ match: ([String: Any]) -> Bool) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            while true {
                if let i = inbox.firstIndex(where: match) { return inbox.remove(at: i) }
                // Messages are delivered on the main queue; keep it running while waiting.
                lock.unlock()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                lock.lock()
                if Date() > deadline { return nil }
            }
        }

        if !client.connect() {
            engineProcess.start()
            let deadline = Date().addingTimeInterval(60)
            while !client.connect() {
                if Date() > deadline { fputs("engine did not start; see \(Paths.engineLog.path)\n", stderr); return 1 }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            }
        }
        client.send(["type": "hello"])
        guard waitFor(Date().addingTimeInterval(600), { ($0["type"] as? String) == "status" && ($0["ready"] as? Bool) == true }) != nil else {
            fputs("engine not ready\n", stderr); return 1
        }

        var failures: Int32 = 0
        for file in files {
            guard let samples = try? loadMono16k(file) else {
                fputs("cannot read \(file)\n", stderr); failures += 1; continue
            }
            let id = UUID().uuidString
            client.send(["type": "begin", "id": id, "app": "selftest", "app_name": "SelfTest"])
            // Same chunking as live capture: 100 ms of Int16 PCM per message.
            var i = 0
            while i < samples.count {
                let chunk = samples[i..<min(i + 1600, samples.count)]
                let pcm = chunk.map { Int16(max(-1, min(1, $0)) * 32767) }
                let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
                client.send(["type": "audio", "id": id, "pcm16": data.base64EncodedString()])
                i += 1600
                if realtime { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            }
            let sent = Date()
            client.send(["type": "end", "id": id])
            guard let res = waitFor(Date().addingTimeInterval(120), { ($0["id"] as? String) == id }) else {
                fputs("timeout on \(file)\n", stderr); failures += 1; continue
            }
            var out = res
            out["file"] = file
            out["client_wait_s"] = Date().timeIntervalSince(sent)
            if let json = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
               let line = String(data: json, encoding: .utf8) {
                print(line)
            }
            if (res["type"] as? String) != "result" { failures += 1 }
        }
        client.disconnect()
        engineProcess.stop()
        return failures
    }

    static func loadMono16k(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let inFormat = file.processingFormat
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return [] }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / inFormat.sampleRate + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
