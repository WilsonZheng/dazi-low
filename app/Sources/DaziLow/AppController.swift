import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

/// Wires hotkey, microphone, engine and paste together.
final class AppController: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyMonitor()
    private let watcher = CorrectionWatcher()
    private let dashboard = DashboardWindow()
    private let recorder = AudioRecorder()
    private let hud = HUD()
    private let engineProcess = EngineProcess()
    private lazy var engine = EngineClient(socketPath: Paths.socket)
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "状态：启动中…", action: nil, keyEquivalent: "")
    private let permissionLine = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "复制上一条", action: #selector(copyLast), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLogin), keyEquivalent: "")
    private let helpItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private var engineReady = false
    private var engineStatus = "启动中…"
    private var axTrusted = false
    private var currentID: String?
    /// Session the audio thread may stream for; only touched on `audioQueue`.
    private var streamingID: String?
    private var targetPID: pid_t?
    private var recordingStarted = Date()
    private var pendingTimeout: DispatchWorkItem?
    private var maxDurationTimer: DispatchWorkItem?
    private var lastText: String?
    /// Samples streamed for the current recording; only touched on `audioQueue`.
    private var sentSamples = 0
    private let audioQueue = DispatchQueue(label: "dazi.audio.send")

    static let maxRecording: TimeInterval = 600
    /// Keep listening this long after release so the last syllable is not clipped.
    static let tailPadding: TimeInterval = 0.2

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy only: a second launch (login item vs. terminal) just exits.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil)
            return
        }
        Paths.ensure()
        setupStatusItem()
        hud.levelProvider = { [weak self] in self?.recorder.level ?? 0 }

        engine.onMessage = { [weak self] msg in self?.handleEngine(msg) }
        engine.onDisconnect = { [weak self] in self?.engineLost() }
        engineProcess.onProblem = { [weak self] problem in
            self?.engineReady = false
            switch problem {
            case .notInstalled: self?.setStatus("引擎未安装，请运行 scripts/install.sh")
            case .crashing: self?.setStatus("引擎反复崩溃，请查看日志")
            }
        }
        engineProcess.start()
        scheduleConnect()

        recorder.onChunk = { [weak self] samples in self?.sendAudio(samples) }
        recorder.prewarm()
        watcher.onCorrections = { [weak self] pairs in
            guard let self else { return }
            self.engine.send(["type": "learn", "pairs": pairs.map { ["from": $0.0, "to": $0.1] }])
            if let first = pairs.first {
                self.hud.show(.message(pairs.count == 1 ? "记住了：\(first.0) → \(first.1)" : "记住了 \(pairs.count) 处修改"))
            }
        }
        hotkey.onAction = { [weak self] action in self?.handleHotkey(action) }
        hotkey.start()
        NotificationCenter.default.addObserver(forName: HotkeySpec.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { // after the monitor reloaded the spec
                self.helpItem.title = self.hotkey.spec.help
                self.hud.setHint(self.hotkey.spec.hint)
            }
        }
        NotificationCenter.default.addObserver(forName: .daziHotkeyRecording, object: nil, queue: .main) { [weak self] n in
            self?.hotkey.paused = (n.object as? Bool) ?? false
        }
        if !hotkey.comboRegistered { NSLog("DaziLow: ⌃⌥Space is taken by another app") }

        requestPermissions()
        enableLaunchAtLoginOnce()
    }

    /// Opening Dazi again (Spotlight, Finder, `open`) while it runs shows the panel, for
    /// when the menu-bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboard.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        engineProcess.stop()
    }

    // MARK: - Permissions

    private func requestPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(opts)
        updatePermissionLine()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        // Accessibility can be granted at any time; pick it up without a relaunch.
        writeStatus()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let now = AXIsProcessTrusted()
            if now != self.axTrusted {
                self.axTrusted = now
                if now { self.hotkey.installMonitors() }
                self.updatePermissionLine()
            }
            self.writeStatus()
        }
    }

    /// status.json lets scripts (and the user) check what works without opening menus.
    private func writeStatus() {
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "granted"
        case .denied, .restricted: mic = "denied"
        default: mic = "not asked"
        }
        let status: [String: Any] = [
            "accessibility": axTrusted, "microphone": mic, "engine_ready": engineReady,
            "engine_status": engineStatus, "fallback_hotkey_registered": hotkey.comboRegistered,
            "updated": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.support.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    private func updatePermissionLine() {
        permissionLine.isHidden = axTrusted
        permissionLine.title = hotkey.comboRegistered
            ? "未开辅助功能：只能按住 ⌃⌥Space 说话，结果需手动 ⌘V（点此打开设置）"
            : "未开辅助功能：快捷键不可用（点此打开设置）"
    }

    private func enableLaunchAtLoginOnce() {
        let key = "registeredLoginItem"
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Engine connection

    private func scheduleConnect(after delay: TimeInterval = 0.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.engine.connect() {
                self.engine.send(["type": "hello"])
            } else if self.engineProcess.problem == nil {
                self.scheduleConnect(after: 1)
            }
        }
    }

    private func engineLost() {
        engineReady = false
        if currentID != nil {
            if recorder.isRunning { recorder.stop() }
            audioQueue.async { self.streamingID = nil }
            finish()
            hotkey.resetAfterExternalStop()
            hud.show(.message("引擎断开，请重试"))
        }
        setStatus("引擎重连中…")
        scheduleConnect(after: 1)
    }

    private func handleEngine(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "status":
            engineReady = msg["ready"] as? Bool ?? false
            setStatus(msg["text"] as? String ?? (engineReady ? "就绪" : "加载中…"))
        case "result":
            let text = (msg["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.write("result: \(text.count) chars, current=\((msg["id"] as? String) == currentID)")
            guard let id = msg["id"] as? String, id == currentID else {
                // A late result (after the timeout) is still kept for "复制上一条".
                if !text.isEmpty { lastText = text; lastItem.isEnabled = true }
                return
            }
            let target = targetPID
            finish()
            guard !text.isEmpty else {
                hud.show(.message("没听清"))
                return
            }
            lastText = text
            lastItem.isEnabled = true
            deliver(text, target: target)
        case "error":
            if let id = msg["id"] as? String, id == currentID { finish() }
            hud.show(.message(msg["text"] as? String ?? "出错了"))
        default:
            break
        }
    }

    private func deliver(_ text: String, target: pid_t?) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        AppLog.write("deliver: ax=\(AXIsProcessTrusted()) sameApp=\(target == nil || front == target)")
        if !AXIsProcessTrusted() {
            Paster.copy(text)
            hud.show(.message("已复制，按 ⌘V 粘贴"))
        } else if let target, front != target {
            // The user moved to another app while we were working: don't paste blind.
            Paster.copy(text)
            hud.show(.message("窗口已切换，已复制"))
        } else {
            hud.show(.hidden)
            Paster.insert(text)
            if let target { watcher.watch(inserted: text, pid: target) }
        }
    }

    // MARK: - Recording

    private func handleHotkey(_ action: HotkeyStateMachine.Action) {
        AppLog.write("hotkey \(action)")
        switch action {
        case .start: startRecording()
        case .commit: commitRecording()
        case .cancel: cancelRecording()
        case .enterHandsFree:
            if recorder.isRunning { hud.setHandsFree(true) } else { hotkey.resetAfterExternalStop() }
        }
    }

    private func refuse(_ message: String) {
        AppLog.write("refused: \(message)")
        hotkey.resetAfterExternalStop()
        hud.show(.message(message))
    }

    private func startRecording() {
        guard currentID == nil else { return refuse("还在处理上一条") }
        guard engineReady, engine.isConnected else { return refuse(engineStatus) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return refuse("需要麦克风权限")
        }
        if IsSecureEventInputEnabled() { return refuse("密码输入中，暂不能听写") }

        watcher.stop()
        let id = UUID().uuidString
        let front = NSWorkspace.shared.frontmostApplication
        targetPID = front?.processIdentifier
        // Window title and the text before the cursor help with names and terms.
        let context = (AXIsProcessTrusted() ? front.map { AXText.context(pid: $0.processIdentifier) } : nil) ?? ""
        engine.send(["type": "begin", "id": id, "context": context,
                     "app": front?.bundleIdentifier ?? "", "app_name": front?.localizedName ?? ""])
        currentID = id
        audioQueue.sync { streamingID = id }
        recordingStarted = Date()
        do {
            try recorder.start()
        } catch {
            engine.send(["type": "cancel", "id": id])
            audioQueue.sync { streamingID = nil }
            currentID = nil
            return refuse(error.localizedDescription)
        }
        Sound.start()
        audioQueue.async { self.sentSamples = 0 }
        AppLog.write("recording started (front app \(front?.bundleIdentifier ?? "?"), context \(context.count) chars)")
        hud.show(.listening(handsFree: false))
        let limit = DispatchWorkItem { [weak self] in
            self?.hotkey.resetAfterExternalStop()
            self?.commitRecording()
        }
        maxDurationTimer = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecording, execute: limit)
    }

    private func commitRecording() {
        guard let id = currentID, recorder.isRunning else { return }
        maxDurationTimer?.cancel()
        hud.show(.processing)
        let duration = Date().timeIntervalSince(recordingStarted)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tailPadding) { [weak self] in
            guard let self, self.currentID == id else { return }
            self.recorder.stop()
            self.audioQueue.async {
                // Runs after every queued chunk; later tap callbacks are dropped.
                self.streamingID = nil
                DispatchQueue.main.async { self.sendEnd(id, duration: duration) }
            }
        }
    }

    private func sendEnd(_ id: String, duration: TimeInterval) {
        guard currentID == id else { return }
        AppLog.write(String(format: "recording ended: held %.2f s, audio sent %.2f s, mic restarts %d",
                            duration, Double(sentSamplesSnapshot()) / 16000, recorder.restarts))
        if duration < 0.35 {
            engine.send(["type": "cancel", "id": id])
            finish()
            hud.show(.hidden)
            return
        }
        Sound.stop()
        engine.send(["type": "end", "id": id])
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.currentID == id else { return }
            AppLog.write("timeout waiting for result; restarting engine")
            self.finish()
            self.hud.show(.message("超时，已重启引擎，请重试"))
            // No answer in time means the engine is stuck or overloaded: start it fresh.
            self.restartEngine()
        }
        pendingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30 + duration * 0.5, execute: timeout)
    }

    private func cancelRecording() {
        guard let id = currentID, recorder.isRunning else { return }
        recorder.stop()
        audioQueue.async { self.streamingID = nil }
        engine.send(["type": "cancel", "id": id])
        finish()
        hud.show(.message("已取消"))
    }

    private func finish() {
        pendingTimeout?.cancel()
        maxDurationTimer?.cancel()
        currentID = nil
        targetPID = nil
    }

    private func sendAudio(_ samples: [Float]) {
        audioQueue.async { [weak self] in
            guard let self, let id = self.streamingID else { return }
            var pcm = [Int16](repeating: 0, count: samples.count)
            for i in 0..<samples.count {
                pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767)
            }
            let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            self.sentSamples += samples.count
            self.engine.send(["type": "audio", "id": id, "pcm16": data.base64EncodedString()])
        }
    }

    private func sentSamplesSnapshot() -> Int {
        audioQueue.sync { sentSamples }
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "Dazi")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        permissionLine.target = self
        menu.addItem(permissionLine)
        helpItem.title = hotkey.spec.help
        helpItem.isEnabled = false
        menu.addItem(helpItem)
        menu.addItem(.separator())
        menu.addItem(item("打开面板（词库、统计、历史）…", #selector(openDashboard), key: ","))
        lastItem.target = self
        lastItem.isEnabled = false
        menu.addItem(lastItem)
        menu.addItem(item("编辑词汇表", #selector(openLexicon)))
        menu.addItem(item("打开历史记录", #selector(openHistory)))
        menu.addItem(item("查看引擎日志", #selector(openLog)))
        menu.addItem(item("重启引擎", #selector(restartEngine)))
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(item("退出 Dazi", #selector(quit), key: "q"))
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func setStatus(_ text: String) {
        engineStatus = text
        statusLine.title = "状态：\(text)"
        statusItem.button?.image = NSImage(systemSymbolName: engineReady ? "mic" : "mic.slash",
                                           accessibilityDescription: "Dazi")
    }

    @objc private func openDashboard() { dashboard.show() }
    @objc private func copyLast() { if let t = lastText { Paster.copy(t) } }
    @objc private func openLexicon() { NSWorkspace.shared.open(Paths.lexicon) }
    @objc private func openHistory() { NSWorkspace.shared.open(Paths.history) }
    @objc private func openLog() { NSWorkspace.shared.open(Paths.engineLog) }
    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func restartEngine() {
        engineReady = false
        setStatus("重启中…")
        engine.disconnect() // does not fire onDisconnect, so reconnect explicitly
        engineProcess.restart()
        scheduleConnect(after: 1.5)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hud.show(.message("设置失败"))
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

enum Sound {
    private static let startSound: NSSound? = { let s = NSSound(named: "Tink"); s?.volume = 0.5; return s }()
    private static let stopSound: NSSound? = { let s = NSSound(named: "Pop"); s?.volume = 0.5; return s }()
    static func start() { startSound?.stop(); startSound?.play() }
    static func stop() { stopSound?.stop(); stopSound?.play() }
}
