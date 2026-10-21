import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--transcribe") {
    let rest = Array(args[(i + 1)...])
    exit(SelfTest.run(files: rest.filter { $0 != "--realtime" }, realtime: rest.contains("--realtime")))
}

if let i = args.firstIndex(of: "--mic-test") {
    // Records for N seconds with the app's recorder and reports what arrived.
    let secs = Double(args.dropFirst(i + 1).first ?? "3") ?? 3
    let rec = AudioRecorder()
    var samples = 0
    var peak: Float = 0
    let lock = NSLock()
    rec.onChunk = { c in lock.lock(); samples += c.count; peak = max(peak, c.map { abs($0) }.max() ?? 0); lock.unlock() }
    do { try rec.start() } catch { print("start failed: \(error)"); exit(1) }
    RunLoop.main.run(until: Date().addingTimeInterval(secs))
    rec.stop()
    lock.lock()
    print(String(format: "recorded %.2f s of audio in %.2f s, peak %.3f, restarts %d", Double(samples) / 16000, secs, peak, rec.restarts))
    exit(samples > 0 ? 0 : 1)
}

if args.contains("--dashboard") {
    // Opens only the dashboard (for checking it without the menu-bar app).
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let dash = DashboardWindow()
    DispatchQueue.main.async { dash.show() }
    app.run()
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
