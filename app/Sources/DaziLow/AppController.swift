import AppKit
import AVFoundation
import ServiceManagement

/// Wires hotkey, microphone, engine and paste together.
final class AppController: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let hud = HUD()
    private let engineProcess = EngineProcess()
    private lazy var engine = EngineClient(socketPath: Paths.socket)
    private var statusItem: NSStatusItem!
    private var statusLine = NSMenuItem(title: "引擎启动中…", action: nil, keyEquivalent: "")
    private var lastItem = NSMenuItem(title: "复制上一条", action: #selector(copyLast), keyEquivalent: "")
    private var loginItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLogin), keyEquivalent: "")

    private var engineReady = false
    private var engineStatus = "启动中…"
    private var currentID: String?
    private var recordingStarted = Date()
    private var pendingTimeout: DispatchWorkItem?
    private var maxDurationTimer: DispatchWorkItem?
    private var lastText: String?
    private let audioQueue = DispatchQueue(label: "dazi.audio.send")

    static let maxRecording: TimeInterval = 600
    static let resultTimeout: TimeInterval = 45

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure()
        setupStatusItem()
        hud.levelProvider = { [weak self] in self?.recorder.level ?? 0 }

        engine.onMessage = { [weak self] msg in self?.handleEngine(msg) }
        engine.onDisconnect = { [weak self] in
            self?.engineReady = false
            self?.setStatus("引擎重连中…")
            self?.scheduleConnect()
        }
        engineProcess.start()
        scheduleConnect()

        recorder.onChunk = { [weak self] samples in self?.sendAudio(samples) }
        hotkey.onAction = { [weak self] action in self?.handleHotkey(action) }
        hotkey.start()

        requestPermissions()
        enableLaunchAtLoginOnce()
    }

    private func enableLaunchAtLoginOnce() {
        let key = "registeredLoginItem"
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func applicationWillTerminate(_ notification: Notification) {
        engineProcess.stop()
    }

    // MARK: - Permissions

    private func requestPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            setStatus("需要辅助功能权限")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    // MARK: - Engine connection

    private func scheduleConnect(after delay: TimeInterval = 0.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.engine.connect() {
                self.engine.send(["type": "hello"])
            } else {
                if !self.engineProcess.isRunning { self.engineProcess.start() }
                self.scheduleConnect(after: 1)
            }
        }
    }

    private func handleEngine(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "status":
            engineReady = msg["ready"] as? Bool ?? false
            setStatus(msg["text"] as? String ?? (engineReady ? "就绪" : "加载中…"))
        case "result":
            guard let id = msg["id"] as? String, id == currentID else { return }
            finish()
            let text = (msg["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                hud.show(.message("没听清"))
                return
            }
            lastText = text
            lastItem.isEnabled = true
            hud.show(.hidden)
            Paster.insert(text)
        case "error":
            if let id = msg["id"] as? String, id == currentID { finish() }
            hud.show(.message(msg["text"] as? String ?? "出错了"))
        default:
            break
        }
    }

    // MARK: - Recording

    private func handleHotkey(_ action: HotkeyStateMachine.Action) {
        switch action {
        case .start: startRecording()
        case .commit: commitRecording()
        case .cancel: cancelRecording()
        case .enterHandsFree: if recorder.isRunning { hud.setHandsFree(true) }
        }
    }

    private func startRecording() {
        guard currentID == nil else { return } // still processing the previous one
        guard engineReady, engine.isConnected else {
            hud.show(.message(engineStatus))
            hotkey.resetAfterExternalStop()
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.show(.message("需要麦克风权限"))
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            hotkey.resetAfterExternalStop()
            return
        }
        let id = UUID().uuidString
        let front = NSWorkspace.shared.frontmostApplication
        engine.send(["type": "begin", "id": id,
                     "app": front?.bundleIdentifier ?? "", "app_name": front?.localizedName ?? ""])
        currentID = id
        recordingStarted = Date()
        do {
            try recorder.start()
        } catch {
            engine.send(["type": "cancel", "id": id])
            currentID = nil
            hotkey.resetAfterExternalStop()
            hud.show(.message(error.localizedDescription))
            return
        }
        Sound.start()
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
        recorder.stop()
        let duration = Date().timeIntervalSince(recordingStarted)
        audioQueue.async { [weak self] in
            // Flush after all queued audio chunks.
            DispatchQueue.main.async {
                guard let self else { return }
                if duration < 0.35 {
                    self.engine.send(["type": "cancel", "id": id])
                    self.finish()
                    self.hud.show(.hidden)
                    return
                }
                Sound.stop()
                self.engine.send(["type": "end", "id": id])
                self.hud.show(.processing)
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.currentID == id else { return }
                    self.finish()
                    self.hud.show(.message("超时，请重试"))
                }
                self.pendingTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultTimeout, execute: timeout)
            }
        }
    }

    private func cancelRecording() {
        guard let id = currentID, recorder.isRunning else { return }
        maxDurationTimer?.cancel()
        recorder.stop()
        engine.send(["type": "cancel", "id": id])
        finish()
        hud.show(.hidden)
    }

    private func finish() {
        pendingTimeout?.cancel()
        maxDurationTimer?.cancel()
        currentID = nil
    }

    private func sendAudio(_ samples: [Float]) {
        audioQueue.async { [weak self] in
            guard let self, let id = self.currentID else { return }
            var pcm = [Int16](repeating: 0, count: samples.count)
            for i in 0..<samples.count {
                pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767)
            }
            let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            self.engine.send(["type": "audio", "id": id, "pcm16": data.base64EncodedString()])
        }
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dazi")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(NSMenuItem(title: "按住右侧 ⌥ 说话，松开插入；轻点一下为免提", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
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

    @objc private func copyLast() { if let t = lastText { Paster.copy(t) } }
    @objc private func openLexicon() { NSWorkspace.shared.open(Paths.lexicon) }
    @objc private func openHistory() { NSWorkspace.shared.open(Paths.history) }
    @objc private func openLog() { NSWorkspace.shared.open(Paths.engineLog) }
    @objc private func restartEngine() {
        engineReady = false
        setStatus("重启中…")
        engine.disconnect()
        engineProcess.restart()
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
    private static let startSound: NSSound? = { let s = NSSound(named: "Tink"); s?.volume = 0.25; return s }()
    private static let stopSound: NSSound? = { let s = NSSound(named: "Pop"); s?.volume = 0.25; return s }()
    static func start() { startSound?.stop(); startSound?.play() }
    static func stop() { stopSound?.stop(); stopSound?.play() }
}
