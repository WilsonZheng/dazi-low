import AppKit

/// Small pill at the bottom of the screen, Typeless-style: a short live waveform and a
/// small clickable 取消 while recording, three bouncing dots while processing.
final class HUD {
    enum Mode: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case processing
        case message(String)
    }

    private static let height: CGFloat = 32
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let wave = WaveformView()
    private let dots = DotsView()
    private let label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var timer: Timer?
    private var hideTimer: Timer?
    var levelProvider: (() -> Float)?
    var onCancel: (() -> Void)?
    private(set) var mode: Mode = .hidden

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        background.frame = panel.contentView!.bounds
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.appearance = NSAppearance(named: .darkAqua)
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2
        background.layer?.masksToBounds = true
        panel.contentView = background

        background.addSubview(wave)
        background.addSubview(dots)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        background.addSubview(label)

        cancelButton.isBordered = false
        cancelButton.attributedTitle = NSAttributedString(string: "取消", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        background.addSubview(cancelButton)
    }

    @objc private func cancelClicked() { onCancel?() }

    func show(_ newMode: Mode) {
        mode = newMode
        timer?.invalidate()
        timer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        wave.isHidden = true
        dots.isHidden = true
        label.isHidden = true
        cancelButton.isHidden = true
        panel.ignoresMouseEvents = true
        switch newMode {
        case .hidden:
            panel.orderOut(nil)
            return
        case .listening:
            // [ waveform ][ 取消 ]
            resize(width: 112)
            wave.frame = NSRect(x: 14, y: 8, width: 52, height: 16)
            wave.reset()
            wave.isHidden = false
            cancelButton.frame = NSRect(x: 72, y: 7, width: 30, height: 18)
            cancelButton.isHidden = false
            panel.ignoresMouseEvents = false // 取消 is clickable
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                self?.wave.push(CGFloat(self?.levelProvider?() ?? 0))
            }
        case .processing:
            resize(width: 56)
            dots.frame = NSRect(x: 0, y: 0, width: 56, height: Self.height)
            dots.isHidden = false
            dots.phase = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.dots.step()
            }
        case .message(let text):
            label.stringValue = text
            let w = min(360, ceil(label.intrinsicContentSize.width) + 28)
            resize(width: w)
            label.frame = NSRect(x: 14, y: 8, width: w - 28, height: 16)
            label.isHidden = false
            hideTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: false) { [weak self] _ in
                self?.show(.hidden)
            }
        }
        position()
        panel.orderFrontRegardless()
    }

    func setHint(_ text: String) {}

    func setHandsFree(_ on: Bool) {
        guard case .listening = mode else { return }
        mode = .listening(handsFree: on)
    }

    private func resize(width: CGFloat) {
        panel.setContentSize(NSSize(width: width, height: Self.height))
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 40))
    }
}

/// A few white bars following the microphone level; newest on the right.
final class WaveformView: NSView {
    private static let bars = 9
    private var samples = [CGFloat](repeating: 0, count: WaveformView.bars)

    func reset() {
        samples = [CGFloat](repeating: 0, count: Self.bars)
        needsDisplay = true
    }

    func push(_ level: CGFloat) {
        let last = samples.last ?? 0
        samples.removeFirst()
        samples.append(max(level, last * 0.5))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(Self.bars)
        let w: CGFloat = 3
        let gap = (bounds.width - w * n) / (n - 1)
        NSColor.white.withAlphaComponent(0.92).setFill()
        for (i, v) in samples.enumerated() {
            let h = max(w, min(bounds.height, w + v * (bounds.height - w)))
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}

/// Three dots bouncing in turn.
final class DotsView: NSView {
    var phase: CGFloat = 0

    func step() {
        phase += 0.12
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 5, gap: CGFloat = 5
        let total = d * 3 + gap * 2
        let x0 = (bounds.width - total) / 2
        for i in 0..<3 {
            let t = phase - CGFloat(i) * 0.6
            let lift = max(0, sin(t)) * 4
            let alpha = 0.45 + 0.55 * max(0, sin(t))
            NSColor.white.withAlphaComponent(alpha).setFill()
            let r = NSRect(x: x0 + CGFloat(i) * (d + gap), y: (bounds.height - d) / 2 + lift, width: d, height: d)
            NSBezierPath(ovalIn: r).fill()
        }
    }
}
