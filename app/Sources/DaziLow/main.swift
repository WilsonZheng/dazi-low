import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--transcribe") {
    exit(SelfTest.run(files: Array(args[(i + 1)...])))
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
