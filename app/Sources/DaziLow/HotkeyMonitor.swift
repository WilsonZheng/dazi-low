import AppKit

/// Watches the Right Option key globally and feeds `HotkeyStateMachine`.
/// Needs the Accessibility permission to see key events of other apps.
final class HotkeyMonitor {
    private static let rightOptionKeyCode: UInt16 = 61
    private static let escapeKeyCode: UInt16 = 53
    /// NX_DEVICERALTKEYMASK: set while the right Option key is physically down.
    private static let rightOptionDeviceMask: UInt = 0x40

    var onAction: ((HotkeyStateMachine.Action) -> Void)?

    private var machine = HotkeyStateMachine()
    private var monitors: [Any] = []
    private var rightOptionDown = false

    var isRecording: Bool { machine.isRecording }

    func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Called when the app ends a recording on its own (time limit, error).
    func resetAfterExternalStop() {
        machine.reset(keyStillDown: rightOptionDown)
    }

    private func handle(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        var action: HotkeyStateMachine.Action?
        switch event.type {
        case .flagsChanged:
            if event.keyCode == Self.rightOptionKeyCode {
                let down = event.modifierFlags.rawValue & Self.rightOptionDeviceMask != 0
                guard down != rightOptionDown else { return }
                rightOptionDown = down
                action = down ? machine.keyDown(at: now) : machine.keyUp(at: now)
            } else if rightOptionDown {
                // Another modifier while holding Right Option: a shortcut chord.
                action = machine.otherKeyDown(at: now)
            }
        case .keyDown:
            if event.keyCode == Self.escapeKeyCode {
                action = machine.escape(keyStillDown: rightOptionDown)
            } else {
                action = machine.otherKeyDown(at: now)
            }
        default:
            break
        }
        if let action { onAction?(action) }
    }
}
