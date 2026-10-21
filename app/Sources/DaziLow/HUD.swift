import AppKit

/// Small floating capsule at the bottom of the screen showing recording state.
final class HUD {
    enum Mode: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case processing
        case message(String)
    }

    private let panel: NSPanel
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let bars: [NSView] = (0..<5).map { _ in NSView() }
    private var timer: Timer?
    private var startedAt = Date()
    var levelProvider: (() -> Float)?
    private(set) var mode: Mode = .hidden

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 190, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.frame = NSRect(x: 16, y: 15, width: 10, height: 10)
        bg.addSubview(dot)

        for (i, b) in bars.enumerated() {
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.8).cgColor
            b.layer?.cornerRadius = 1.5
            b.frame = NSRect(x: 34 + CGFloat(i) * 6, y: 17, width: 3, height: 6)
            bg.addSubview(b)
        }

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 70, y: 11, width: 112, height: 18)
        label.lineBreakMode = .byTruncatingTail
        bg.addSubview(label)
    }

    func show(_ newMode: Mode) {
        mode = newMode
        timer?.invalidate()
        timer = nil
        switch newMode {
        case .hidden:
            panel.orderOut(nil)
            return
        case .listening(let handsFree):
            startedAt = Date()
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            bars.forEach { $0.isHidden = false }
            label.frame.origin.x = 70
            label.stringValue = handsFree ? "0:00 免提" : "0:00"
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.tick(handsFree: handsFree)
            }
        case .processing:
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            bars.forEach { $0.isHidden = true }
            label.frame.origin.x = 36
            label.stringValue = "整理中…"
        case .message(let text):
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            bars.forEach { $0.isHidden = true }
            label.frame.origin.x = 36
            label.stringValue = text
            timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                self?.show(.hidden)
            }
        }
        position()
        panel.orderFrontRegardless()
    }

    func setHandsFree(_ on: Bool) {
        guard case .listening = mode else { return }
        let started = startedAt
        show(.listening(handsFree: on))
        startedAt = started
    }

    private func tick(handsFree: Bool) {
        let level = CGFloat(levelProvider?() ?? 0)
        for (i, b) in bars.enumerated() {
            let wobble = CGFloat(abs(sin(Date().timeIntervalSince1970 * 9 + Double(i) * 1.3)))
            let h = max(4, min(22, 4 + level * 22 * (0.55 + 0.45 * wobble)))
            b.frame = NSRect(x: b.frame.origin.x, y: 20 - h / 2, width: 3, height: h)
        }
        let secs = Int(Date().timeIntervalSince(startedAt))
        let t = String(format: "%d:%02d", secs / 60, secs % 60)
        label.stringValue = handsFree ? "\(t) 免提" : t
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 36))
    }
}
