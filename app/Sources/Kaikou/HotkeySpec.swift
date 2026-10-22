import AppKit
import Carbon.HIToolbox

/// The user's dictation shortcut, stored in UserDefaults and edited in the panel.
///
/// Two kinds:
/// - modifier-only (`keyCode == nil`): exact set of device-specific modifier keys, e.g.
///   left Control + left Shift. Watched with NSEvent monitors (needs Accessibility).
/// - key combo: modifiers + a key, e.g. ⌥Space. Registered as a Carbon hot key, which
///   swallows the keystroke and needs no permission.
struct HotkeySpec: Codable, Equatable {
    enum Mode: String, Codable {
        case toggle // press once to start, again to finish
        case hold   // hold to talk, release to finish
    }

    /// Device-specific modifier bits (NX_DEVICE*KEYMASK) for modifier-only specs;
    /// device-independent NSEvent.ModifierFlags raw value for key combos.
    var modifiers: UInt
    var keyCode: UInt16?
    var keyName: String?
    var mode: Mode
    /// Modifier-only specs: two quick presses start (a single press then finishes).
    var doubleTap: Bool? = nil
    var isDoubleTap: Bool { doubleTap == true && keyCode == nil }

    /// Default: press fn twice to start, press fn once to finish.
    static let `default` = HotkeySpec(modifiers: Bits.fn, keyCode: nil, keyName: nil, mode: .toggle, doubleTap: true)
    static let changed = Notification.Name("KaikouHotkeyChanged")
    private static let defaultsKey = "hotkeySpec"

    enum Bits {
        static let leftControl: UInt = 0x0001, rightControl: UInt = 0x2000
        static let leftShift: UInt = 0x0002, rightShift: UInt = 0x0004
        static let leftCommand: UInt = 0x0008, rightCommand: UInt = 0x0010
        static let leftOption: UInt = 0x0020, rightOption: UInt = 0x0040
        /// Not a device bit: the fn/globe key, taken from NSEvent.ModifierFlags.function.
        static let fn: UInt = 0x0080_0000
        static let all: UInt = leftControl | rightControl | leftShift | rightShift | leftCommand | rightCommand
            | leftOption | rightOption | fn
        static let names: [(UInt, String)] = [
            (fn, "fn"), (leftControl, "左⌃"), (rightControl, "右⌃"), (leftOption, "左⌥"), (rightOption, "右⌥"),
            (leftShift, "左⇧"), (rightShift, "右⇧"), (leftCommand, "左⌘"), (rightCommand, "右⌘"),
        ]
    }

    static func load() -> HotkeySpec {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data) else { return .default }
        return spec
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Device bits (plus fn) of an event's modifier state.
    static func deviceBits(_ flags: NSEvent.ModifierFlags) -> UInt {
        var bits = flags.rawValue & (Bits.all & ~Bits.fn)
        if flags.contains(.function) { bits |= Bits.fn }
        return bits
    }

    var display: String {
        if let keyCode {
            let f = NSEvent.ModifierFlags(rawValue: modifiers)
            var s = ""
            if f.contains(.control) { s += "⌃" }
            if f.contains(.option) { s += "⌥" }
            if f.contains(.shift) { s += "⇧" }
            if f.contains(.command) { s += "⌘" }
            return s + (keyName ?? "键\(keyCode)")
        }
        let keys = Bits.names.filter { modifiers & $0.0 != 0 }.map(\.1).joined(separator: " ")
        return isDoubleTap ? "双击 \(keys)" : keys
    }

    var hint: String {
        mode == .toggle ? "\(display) 结束 · Esc 取消" : "松开结束 · Esc 取消"
    }

    var help: String {
        if isDoubleTap {
            let key = display.replacingOccurrences(of: "双击 ", with: "")
            return "连按两下 \(key) 开始说话，再按一下 \(key) 结束；Esc 取消"
        }
        return mode == .toggle ? "按一下 \(display) 开始说话，再按一下结束；Esc 取消" : "按住 \(display) 说话，松开结束；Esc 取消"
    }

    /// Why a recorded spec is unsafe, or nil if it is fine.
    var problem: String? {
        if keyCode != nil {
            let f = NSEvent.ModifierFlags(rawValue: modifiers).intersection([.control, .option, .shift, .command])
            return f.isEmpty ? "单独一个普通键会挡住打字，请加上修饰键（比如 ⌥ 或 ⌃）" : nil
        }
        let count = Bits.names.filter { modifiers & $0.0 != 0 }.count
        if count == 0 { return "没有按到修饰键" }
        if count == 1 {
            let safe: [UInt] = [Bits.rightOption, Bits.rightCommand, Bits.rightControl, Bits.fn]
            if !safe.contains(modifiers) { return "单独一个左边的 ⌃/⌥/⇧/⌘ 太容易误触，请用两个键的组合，或右边的单键" }
        }
        return nil
    }

    var carbonModifiers: UInt32 {
        let f = NSEvent.ModifierFlags(rawValue: modifiers)
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        default:
            if let fkey = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                           kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
                           kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15"][Int(event.keyCode)] {
                return fkey
            }
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
