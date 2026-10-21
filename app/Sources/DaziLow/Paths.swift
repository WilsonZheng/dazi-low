import Foundation

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DaziLow", isDirectory: true)
    }()
    static let logs: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DaziLow", isDirectory: true)
    static var socket: String { support.appendingPathComponent("engine.sock").path }
    static var python: URL { support.appendingPathComponent("venv/bin/python") }
    static var lexicon: URL { support.appendingPathComponent("lexicon.json") }
    static var history: URL { support.appendingPathComponent("history", isDirectory: true) }
    static var engineLog: URL { logs.appendingPathComponent("engine.log") }

    /// Engine sources: `DAZI_ENGINE_DIR` (development), else the copy the installer puts in
    /// Application Support, else the one inside the bundle. Keeping the engine outside the
    /// bundle means engine updates do not change the app's signature, so macOS keeps the
    /// Microphone and Accessibility grants.
    static var engineDir: URL {
        if let dev = ProcessInfo.processInfo.environment["DAZI_ENGINE_DIR"] {
            return URL(fileURLWithPath: dev, isDirectory: true)
        }
        let installed = support.appendingPathComponent("engine", isDirectory: true)
        if FileManager.default.fileExists(atPath: installed.appendingPathComponent("server.py").path) {
            return installed
        }
        return Bundle.main.resourceURL!.appendingPathComponent("engine", isDirectory: true)
    }

    static func ensure() {
        for dir in [support, logs, history] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
