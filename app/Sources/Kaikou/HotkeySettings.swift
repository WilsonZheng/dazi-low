import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted with `object: Bool` while the panel records a new shortcut, so the live
    /// shortcut does not start a dictation meanwhile.
    static let kaikouHotkeyRecording = Notification.Name("KaikouHotkeyRecording")
}

/// Captures the next shortcut pressed in the panel window.
final class HotkeyRecorder: ObservableObject {
    @Published var recording = false
    @Published var spec = HotkeySpec.load()
    @Published var message: String?
    private var monitor: Any?
    private var peak: UInt = 0

    func start() {
        stop()
        peak = 0
        message = "请按下新的快捷键（按 Esc 放弃）…"
        recording = true
        NotificationCenter.default.post(name: .kaikouHotkeyRecording, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            self?.handle(e)
            return nil // swallow while recording
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording { NotificationCenter.default.post(name: .kaikouHotkeyRecording, object: false) }
        recording = false
    }

    func setMode(_ mode: HotkeySpec.Mode) {
        spec.mode = mode
        spec.save()
    }

    func reset() {
        finish(HotkeySpec.default)
    }

    func setDoubleTap(_ on: Bool) {
        guard spec.keyCode == nil else { return }
        spec.doubleTap = on
        if on { spec.mode = .toggle }
        spec.save()
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .flagsChanged:
            let bits = HotkeySpec.deviceBits(e.modifierFlags)
            peak |= bits
            if bits == 0 && peak != 0 {
                finish(HotkeySpec(modifiers: peak, keyCode: nil, keyName: nil, mode: spec.mode, doubleTap: spec.doubleTap))
            }
        case .keyDown:
            let mods = e.modifierFlags.intersection([.control, .option, .shift, .command])
            if e.keyCode == 53 && mods.isEmpty {
                message = "已放弃，快捷键没有改。"
                stop()
                return
            }
            finish(HotkeySpec(modifiers: mods.rawValue, keyCode: e.keyCode, keyName: HotkeySpec.keyName(e), mode: spec.mode))
        default:
            break
        }
    }

    private func finish(_ candidate: HotkeySpec) {
        stop()
        if let problem = candidate.problem {
            message = "不能用 \(candidate.display)：\(problem)"
            return
        }
        spec = candidate
        spec.save()
        message = "已保存，现在就生效：\(spec.help)"
    }
}

struct SettingsView: View {
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("听写快捷键").font(.headline)
            HStack(spacing: 12) {
                Text(recorder.recording ? "…" : recorder.spec.display)
                    .font(.title2.monospaced())
                    .frame(minWidth: 160, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Button(recorder.recording ? "录制中…" : "录制新快捷键") { recorder.start() }
                    .disabled(recorder.recording)
                Button("恢复默认（双击 fn）") { recorder.reset() }
            }
            Picker("用法", selection: Binding(get: { recorder.spec.mode }, set: { recorder.setMode($0) })) {
                Text("按一下开始，再按一下结束").tag(HotkeySpec.Mode.toggle)
                Text("按住说话，松开结束").tag(HotkeySpec.Mode.hold)
            }
            .pickerStyle(.radioGroup)
            .disabled(recorder.spec.isDoubleTap)
            Toggle("按两下触发（连按两下开始，再按一下结束）", isOn: Binding(get: { recorder.spec.isDoubleTap },
                                                         set: { recorder.setDoubleTap($0) }))
                .disabled(recorder.spec.keyCode != nil)
            if let m = recorder.message {
                Text(m).foregroundStyle(m.hasPrefix("不能") ? .red : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("可以录：两个及以上修饰键的组合（如 左⌃ 左⇧、⌥⌘），右边的单个修饰键（如 右⌥），fn，或修饰键加一个键（如 ⌥Space、⌃`）。")
                Text("修饰键加普通键的组合会被 Kaikou 独占，不再输入到其他 App。录音时随时按 Esc 取消。")
                Text("备用快捷键 ⌃⌥Space（按住说话）始终可用，不需要辅助功能权限。")
                Text("用 fn 时：如果系统设置里打开了 macOS 自带的听写并且它的快捷键也是 fn，两者会冲突，可以把系统听写关掉或换键。")
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .onDisappear { recorder.stop() }
    }
}
