import AppKit
import Carbon.HIToolbox

/// Feeds `HotkeyStateMachine` from two sources:
/// - Right Option alone, via NSEvent monitors (needs the Accessibility permission).
/// - ⌃⌥Space, via a Carbon hot key, which works without any permission, so dictation
///   still works (copy-to-clipboard mode) before Accessibility is granted.
final class HotkeyMonitor {
    private static let rightOptionKeyCode: UInt16 = 61
    private static let escapeKeyCode: UInt16 = 53
    /// NX_DEVICERALTKEYMASK: set while the right Option key is physically down.
    private static let rightOptionDeviceMask: UInt64 = 0x40

    var onAction: ((HotkeyStateMachine.Action) -> Void)?

    private var machine = HotkeyStateMachine()
    private var monitors: [Any] = []
    private var rightOptionDown = false
    private var comboDown = false
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var isRecording: Bool { machine.isRecording }
    var isHolding: Bool { if case .holding = machine.state { return true }; return false }

    func start() {
        installMonitors()
        registerCombo()
    }

    /// (Re)installs the NSEvent monitors; call again once Accessibility is granted,
    /// because monitors installed before that usually receive nothing.
    func installMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(local)
        }
    }

    /// Called when the app ends a recording on its own (time limit, error, busy).
    func resetAfterExternalStop() {
        machine.reset(keyStillDown: rightOptionDown || comboDown)
    }

    /// Recovers from a missed key-up (e.g. released while secure input was on). Uses the
    /// device-independent Option flag, which is reliable for a physical key, and needs two
    /// misses in a row so a single odd reading never ends a recording.
    private var releasedTicks = 0

    func resyncPhysicalState() {
        guard rightOptionDown, !comboDown else { releasedTicks = 0; return }
        if NSEvent.modifierFlags.contains(.option) {
            releasedTicks = 0
            return
        }
        releasedTicks += 1
        guard releasedTicks >= 2 else { return }
        releasedTicks = 0
        rightOptionDown = false
        AppLog.write("resync: Option no longer held; treating as released")
        emit(machine.keyUp(at: ProcessInfo.processInfo.systemUptime))
    }

    private func emit(_ action: HotkeyStateMachine.Action?) {
        if let action { onAction?(action) }
    }

    private func handle(_ event: NSEvent) {
        // event.timestamp shares systemUptime's clock and is immune to main-thread stalls.
        let now = event.timestamp
        switch event.type {
        case .flagsChanged:
            let down = UInt64(event.modifierFlags.rawValue) & Self.rightOptionDeviceMask != 0
            if event.keyCode == Self.rightOptionKeyCode {
                guard down != rightOptionDown else { return }
                rightOptionDown = down
                emit(down ? machine.keyDown(at: now) : machine.keyUp(at: now))
            } else if rightOptionDown {
                if !down { // the release was missed; the flags say it is up now
                    rightOptionDown = false
                    AppLog.write("flagsChanged shows Right Option up without its own event")
                    emit(machine.keyUp(at: now))
                } else {
                    emit(machine.otherKeyDown(at: now)) // another modifier: a shortcut chord
                }
            }
        case .keyDown:
            if event.keyCode == Self.escapeKeyCode {
                emit(machine.escape(keyStillDown: rightOptionDown || comboDown))
            } else if !comboDown {
                emit(machine.otherKeyDown(at: now))
            }
        default:
            break
        }
    }

    // MARK: - ⌃⌥Space via Carbon (no permission needed)

    /// False if another app already owns the combo.
    private(set) var comboRegistered = false

    private func registerCombo() {
        var spec = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user -> OSStatus in
            guard let event, let user else { return noErr }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(user).takeUnretainedValue()
            monitor.handleCombo(pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, 2, &spec, me, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x445A_4C57), id: 1) // "DZLW"
        // ⌥Space is often taken (Claude desktop quick entry, launchers); ⌃Space switches input sources.
        comboRegistered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | controlKey), id,
                                              GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    private func handleCombo(pressed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard pressed != comboDown else { return }
        comboDown = pressed
        emit(pressed ? machine.keyDown(at: now) : machine.keyUp(at: now))
    }
}
