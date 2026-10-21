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

    /// Engine sources ship inside the app bundle; `DAZI_ENGINE_DIR` overrides for development.
    static var engineDir: URL {
        if let dev = ProcessInfo.processInfo.environment["DAZI_ENGINE_DIR"] {
            return URL(fileURLWithPath: dev, isDirectory: true)
        }
        return Bundle.main.resourceURL!.appendingPathComponent("engine", isDirectory: true)
    }

    static func ensure() {
        for dir in [support, logs, history] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
