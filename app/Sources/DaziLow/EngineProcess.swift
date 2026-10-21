import Foundation

/// Launches the Python engine and restarts it if it dies.
final class EngineProcess {
    private var process: Process?
    private var restarts: [Date] = []
    private var stopping = false
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        stopping = false
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.python.path) else {
            NSLog("DaziLow: engine venv missing at \(Paths.python.path)")
            return
        }
        try? FileManager.default.removeItem(atPath: Paths.socket)
        let p = Process()
        p.executableURL = Paths.python
        p.arguments = ["-u", Paths.engineDir.appendingPathComponent("server.py").path,
                       "--socket", Paths.socket, "--support", Paths.support.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        p.environment = env
        p.currentDirectoryURL = Paths.support
        if !FileManager.default.fileExists(atPath: Paths.engineLog.path) {
            FileManager.default.createFile(atPath: Paths.engineLog.path, contents: nil)
        }
        if let log = try? FileHandle(forWritingTo: Paths.engineLog) {
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleExit(proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("DaziLow: failed to start engine: \(error)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
    }

    private func handleExit(_ status: Int32) {
        process = nil
        onExit?(status)
        guard !stopping else { return }
        // Back off if it keeps crashing: at most 5 restarts per minute.
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard restarts.count <= 5 else {
            NSLog("DaziLow: engine keeps crashing, giving up; see \(Paths.engineLog.path)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
    }
}
