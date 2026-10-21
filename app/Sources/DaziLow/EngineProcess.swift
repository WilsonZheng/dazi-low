import Foundation

/// Launches the Python engine and restarts it if it dies.
///
/// The engine gets a pipe as stdin and exits when it closes, so a crashed or
/// force-quit app never leaves a multi-GB engine behind.
final class EngineProcess {
    enum Problem: Equatable {
        case notInstalled
        case crashing
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var log: FileHandle?
    private var restarts: [Date] = []
    private var stopping = false
    private(set) var problem: Problem?
    var onProblem: ((Problem) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        stopping = false
        guard !isRunning, problem != .crashing else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.python.path) else {
            report(.notInstalled)
            return
        }
        try? FileManager.default.removeItem(atPath: Paths.socket)
        let p = Process()
        p.executableURL = Paths.python
        p.arguments = ["-u", Paths.engineDir.appendingPathComponent("server.py").path,
                       "--socket", Paths.socket, "--support", Paths.support.path, "--exit-on-stdin-eof"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HUB_OFFLINE"] = "1" // models are downloaded by the installer
        env["TOKENIZERS_PARALLELISM"] = "false"
        p.environment = env
        p.currentDirectoryURL = Paths.support
        let stdin = Pipe()
        p.standardInput = stdin
        if !FileManager.default.fileExists(atPath: Paths.engineLog.path) {
            FileManager.default.createFile(atPath: Paths.engineLog.path, contents: nil)
        }
        try? log?.close()
        log = try? FileHandle(forWritingTo: Paths.engineLog)
        log?.seekToEndOfFile()
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                // Ignore exits of a process we already replaced.
                guard let self, proc === self.process else { return }
                self.handleExit(proc.terminationStatus)
            }
        }
        do {
            try p.run()
            process = p
            stdinPipe = stdin
            problem = nil
        } catch {
            NSLog("DaziLow: failed to start engine: \(error)")
            report(.notInstalled)
        }
    }

    func stop() {
        stopping = true
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    /// Manual restart from the menu also clears a "keeps crashing" state.
    func restart() {
        stop()
        restarts.removeAll()
        problem = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
    }

    private func report(_ p: Problem) {
        problem = p
        onProblem?(p)
    }

    private func handleExit(_ status: Int32) {
        process = nil
        stdinPipe = nil
        guard !stopping else { return }
        // Back off if it keeps crashing: at most 5 restarts per minute.
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard restarts.count <= 5 else {
            NSLog("DaziLow: engine keeps crashing (status \(status)); see \(Paths.engineLog.path)")
            report(.crashing)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
    }
}
