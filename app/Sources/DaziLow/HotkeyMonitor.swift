import AppKit
import Carbon.HIToolbox

/// Feeds `HotkeyStateMachine` from two sources:
/// - Left Control + Shift pressed together and released (a tap of the combo, nothing
///   else pressed): starts recording; the next tap finishes it. Needs Accessibility.
/// - ⌃⌥Space held, via a Carbon hot key, which works without any permission, so
///   dictation still works (copy-to-clipboard mode) before Accessibility is granted.
final class HotkeyMonitor {
    private static let escapeKeyCode: UInt16 = 53
    // Device-dependent modifier bits (NX_DEVICE*KEYMASK).
    private static let leftControlMask: UInt = 0x0001
    private static let shiftMasks: UInt = 0x0002 | 0x0004
    /// A combo held longer than this is someone holding keys, not a tap.
    private static let maxTap: TimeInterval = 1.0

    var onAction: ((HotkeyStateMachine.Action) -> Void)?

    private var machine = HotkeyStateMachine()
    private var monitors: [Any] = []
    private var comboDown = false
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    // Left Control + Shift tap tracking.
    private var chordDown = false
    private var chordStart: TimeInterval = 0
    private var chordSpoiled = false

    var isRecording: Bool { machine.isRecording }

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
        machine.reset(keyStillDown: comboDown)
    }

    private func emit(_ action: HotkeyStateMachine.Action?) {
        if let action { onAction?(action) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleModifiers(event)
        case .keyDown:
            if chordDown { chordSpoiled = true } // ⌃⇧ + a key is a shortcut, not our tap
            if event.keyCode == Self.escapeKeyCode {
                emit(machine.escape(keyStillDown: comboDown))
            } else if !comboDown {
                emit(machine.otherKeyDown(at: event.timestamp))
            }
        default:
            break
        }
    }

    private func handleModifiers(_ event: NSEvent) {
        let raw = event.modifierFlags.rawValue
        let flags = event.modifierFlags
        let leftControl = raw & Self.leftControlMask != 0
        let shift = raw & Self.shiftMasks != 0
        let others = flags.contains(.option) || flags.contains(.command) || flags.contains(.function)
        if leftControl && shift {
            if !chordDown {
                chordDown = true
                chordStart = event.timestamp
                chordSpoiled = others
            } else if others {
                chordSpoiled = true
            }
            return
        }
        guard chordDown else { return }
        // The combo was broken by releasing one of its keys: that is the tap.
        chordDown = false
        let quick = event.timestamp - chordStart <= Self.maxTap
        if !chordSpoiled && quick {
            emit(machine.toggle())
        } else {
            AppLog.write("⌃⇧ ignored (spoiled \(chordSpoiled), quick \(quick))")
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
