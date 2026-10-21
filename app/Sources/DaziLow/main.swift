import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--transcribe") {
    let rest = Array(args[(i + 1)...])
    exit(SelfTest.run(files: rest.filter { $0 != "--realtime" }, realtime: rest.contains("--realtime")))
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
