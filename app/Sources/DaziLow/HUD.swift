import AppKit

/// Floating capsule at the bottom of the screen: a live waveform while recording
/// (scrolling right to left, driven by the microphone level), a pulse while processing.
final class HUD {
    enum Mode: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case processing
        case message(String)
    }

    private let panel: NSPanel
    private let wave = WaveformView()
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var hideTimer: Timer?
    private var startedAt = Date()
    private var handsFree = false
    var levelProvider: (() -> Float)?
    private(set) var mode: Mode = .hidden

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
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
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 22
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        wave.frame = NSRect(x: 16, y: 8, width: 150, height: 28)
        bg.addSubview(wave)

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .right
        label.frame = NSRect(x: 168, y: 13, width: 58, height: 18)
        label.lineBreakMode = .byTruncatingTail
        bg.addSubview(label)
    }

    func show(_ newMode: Mode) {
        mode = newMode
        timer?.invalidate()
        timer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        switch newMode {
        case .hidden:
            panel.orderOut(nil)
            return
        case .listening(let free):
            startedAt = Date()
            handsFree = free
            wave.reset(color: .systemRed)
            wave.isHidden = false
            layout(message: false)
            // 20 samples/s over 30 bars: the last 1.5 s of speech.
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
            tick()
        case .processing:
            wave.color = .systemBlue
            wave.isHidden = false
            layout(message: false)
            label.stringValue = "整理中"
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.wave.pulse()
            }
        case .message(let text):
            wave.isHidden = true
            layout(message: true)
            label.stringValue = text
            hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                self?.show(.hidden)
            }
        }
        position()
        panel.orderFrontRegardless()
    }

    func setHandsFree(_ on: Bool) {
        guard case .listening = mode else { return }
        handsFree = on
        mode = .listening(handsFree: on)
    }

    private func layout(message: Bool) {
        if message {
            label.alignment = .center
            label.frame = NSRect(x: 14, y: 13, width: 212, height: 18)
        } else {
            label.alignment = .right
            label.frame = NSRect(x: 168, y: 13, width: 58, height: 18)
        }
    }

    private func tick() {
        wave.push(CGFloat(levelProvider?() ?? 0))
        let secs = Int(Date().timeIntervalSince(startedAt))
        let t = String(format: "%d:%02d", secs / 60, secs % 60)
        label.stringValue = handsFree ? "免提 \(t)" : t
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 36))
    }
}

/// Rolling bar waveform; newest sample on the right.
final class WaveformView: NSView {
    private static let bars = 30
    private var samples = [CGFloat](repeating: 0, count: WaveformView.bars)
    private var phase: CGFloat = 0
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    func reset(color: NSColor) {
        samples = [CGFloat](repeating: 0, count: Self.bars)
        self.color = color
    }

    func push(_ level: CGFloat) {
        // Smooth a little so the bars move like speech, not like noise.
        let last = samples.last ?? 0
        samples.removeFirst()
        samples.append(max(level, last * 0.55))
        needsDisplay = true
    }

    func pulse() {
        phase += 0.18
        samples = (0..<Self.bars).map { i in 0.25 + 0.2 * (1 + sin(phase - CGFloat(i) * 0.35)) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(Self.bars)
        let gap: CGFloat = 2
        let w = (bounds.width - gap * (n - 1)) / n
        color.setFill()
        for (i, v) in samples.enumerated() {
            let h = max(3, min(bounds.height, 3 + v * (bounds.height - 3)))
            let x = CGFloat(i) * (w + gap)
            let r = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}
