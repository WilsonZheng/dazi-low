import AppKit
import Carbon.HIToolbox

/// Feeds `HotkeyStateMachine` from the user's shortcut (`HotkeySpec`, editable in the
/// panel) plus ⌃⌥Space held as a fallback that needs no permission (copy-to-clipboard
/// mode before Accessibility is granted).
final class HotkeyMonitor {
    private static let escapeKeyCode: UInt16 = 53
    /// A modifier combo held longer than this is someone holding keys, not a tap.
    private static let maxTap: TimeInterval = 1.0
    private static let fallbackID: UInt32 = 1
    private static let primaryID: UInt32 = 2

    var onAction: ((HotkeyStateMachine.Action) -> Void)?
    private(set) var spec = HotkeySpec.load()

    private var machine = HotkeyStateMachine()
    private var monitors: [Any] = []
    private var heldKeys: Set<UInt32> = []
    private var fallbackRef: EventHotKeyRef?
    private var primaryRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var specObserver: NSObjectProtocol?

    // Modifier-combo tracking.
    private var chordDown = false
    private var chordStart: TimeInterval = 0
    private var chordSpoiled = false

    var isRecording: Bool { machine.isRecording }
    /// Paused while the panel records a new shortcut.
    var paused = false

    func start() {
        installMonitors()
        installCarbonHandler()
        registerHotKeys()
        specObserver = NotificationCenter.default.addObserver(forName: HotkeySpec.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    private func reload() {
        spec = HotkeySpec.load()
        chordDown = false
        machine.reset(keyStillDown: false)
        registerHotKeys()
        AppLog.write("hotkey changed to \(spec.display) (\(spec.mode.rawValue))")
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
        machine.reset(keyStillDown: !heldKeys.isEmpty || chordDown)
    }

    private func emit(_ action: HotkeyStateMachine.Action?) {
        if let action, !paused { onAction?(action) }
    }

    private func handle(_ event: NSEvent) {
        guard !paused else { return }
        switch event.type {
        case .flagsChanged:
            if spec.keyCode == nil { handleModifiers(event) }
        case .keyDown:
            if chordDown { chordSpoiled = true } // combo + a key is some other shortcut
            if event.keyCode == Self.escapeKeyCode {
                emit(machine.escape(keyStillDown: !heldKeys.isEmpty || chordDown))
            } else if heldKeys.isEmpty {
                emit(machine.otherKeyDown(at: event.timestamp))
            }
        default:
            break
        }
    }

    private func handleModifiers(_ event: NSEvent) {
        let bits = HotkeySpec.deviceBits(event.modifierFlags)
        if bits == spec.modifiers {
            if !chordDown {
                chordDown = true
                chordStart = event.timestamp
                chordSpoiled = false
                if spec.mode == .hold { emit(machine.keyDown(at: event.timestamp)) }
            }
            return
        }
        guard chordDown else { return }
        if bits & ~spec.modifiers != 0 {
            chordSpoiled = true // an extra modifier joined: some other shortcut
            if spec.mode == .hold { emit(machine.otherKeyDown(at: event.timestamp)) }
        }
        if spec.modifiers & ~bits == 0 { return } // all our keys still down
        chordDown = false
        switch spec.mode {
        case .hold:
            emit(machine.keyUp(at: event.timestamp))
        case .toggle:
            let quick = event.timestamp - chordStart <= Self.maxTap
            if !chordSpoiled && quick {
                emit(machine.toggle())
            } else {
                AppLog.write("\(spec.display) ignored (spoiled \(chordSpoiled), quick \(quick))")
            }
        }
    }

    // MARK: - Carbon hot keys (key combos; no permission needed)

    /// False if another app already owns ⌃⌥Space.
    private(set) var comboRegistered = false

    private func installCarbonHandler() {
        var spec = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user -> OSStatus in
            guard let event, let user else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(user).takeUnretainedValue()
            monitor.handleHotKey(id: id.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, 2, &spec, me, &handlerRef)
    }

    private func registerHotKeys() {
        if let r = primaryRef { UnregisterEventHotKey(r); primaryRef = nil }
        if let r = fallbackRef { UnregisterEventHotKey(r); fallbackRef = nil }
        heldKeys.removeAll()
        if let key = spec.keyCode {
            let id = EventHotKeyID(signature: OSType(0x445A_4C57), id: Self.primaryID)
            let ok = RegisterEventHotKey(UInt32(key), spec.carbonModifiers, id, GetApplicationEventTarget(), 0, &primaryRef)
            if ok != noErr { AppLog.write("could not register \(spec.display): taken by another app") }
        }
        // ⌥Space is often taken (Claude desktop quick entry, launchers); ⌃Space switches input sources.
        let fallbackIsPrimary = spec.keyCode == UInt16(kVK_Space) && spec.carbonModifiers == UInt32(optionKey | controlKey)
        if !fallbackIsPrimary {
            let id = EventHotKeyID(signature: OSType(0x445A_4C57), id: Self.fallbackID)
            comboRegistered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | controlKey), id,
                                                  GetApplicationEventTarget(), 0, &fallbackRef) == noErr
        } else {
            comboRegistered = true
        }
    }

    private func handleHotKey(id: UInt32, pressed: Bool) {
        guard !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wasDown = heldKeys.contains(id)
        guard pressed != wasDown else { return } // key repeat
        if pressed { heldKeys.insert(id) } else { heldKeys.remove(id) }
        if id == Self.primaryID && spec.mode == .toggle {
            if pressed { emit(machine.toggle()) }
        } else {
            emit(pressed ? machine.keyDown(at: now) : machine.keyUp(at: now))
        }
    }
}
