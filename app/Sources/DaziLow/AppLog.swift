import Foundation

/// Small event log at ~/Library/Logs/DaziLow/app.log (no dictated text, only events),
/// so a failed dictation can be explained afterwards.
enum AppLog {
    private static let queue = DispatchQueue(label: "dazi.applog")
    private static let url = Paths.logs.appendingPathComponent("app.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}
