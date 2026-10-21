import AppKit
import Charts
import SwiftUI

// MARK: - Data

struct DictationRecord: Identifiable {
    let id: String
    let date: Date
    let app: String
    let duration: Double
    let text: String
    let wait: Double?
}

struct LearnedItem: Identifiable, Hashable {
    var id: String { from + "→" + to }
    let from: String
    let to: String
    let count: Int
}

/// Reads history, lexicon and learned corrections from Application Support, and writes
/// vocabulary edits back (the engine reloads them when idle).
final class DashboardStore: ObservableObject {
    @Published var records: [DictationRecord] = []
    @Published var terms: [String] = []
    @Published var rules: [(String, String)] = []
    @Published var learned: [LearnedItem] = []

    private var lexiconURL: URL { Paths.lexicon }
    private var learnedURL: URL { Paths.support.appendingPathComponent("learned.json") }

    func reload() {
        records = Self.loadHistory()
        let lex = (try? JSONSerialization.jsonObject(with: Data(contentsOf: lexiconURL))) as? [String: Any] ?? [:]
        let hot = (lex["hotwords"] as? [String]) ?? []
        let all = ((lex["terms"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["term"] as? String ?? $0 as? String }
        terms = Array(NSOrderedSet(array: hot + all)) as? [String] ?? hot
        rules = ((lex["replacements"] as? [[String: Any]]) ?? []).flatMap { r -> [(String, String)] in
            let to = r["to"] as? String ?? ""
            let froms = (r["from"] as? [String]) ?? [(r["from"] as? String) ?? ""]
            return froms.map { ($0, to) }
        }
        let l = (try? JSONSerialization.jsonObject(with: Data(contentsOf: learnedURL))) as? [String: Any] ?? [:]
        learned = ((l["corrections"] as? [[String: Any]]) ?? []).map {
            LearnedItem(from: $0["from"] as? String ?? "", to: $0["to"] as? String ?? "", count: $0["count"] as? Int ?? 1)
        }.sorted { $0.count > $1.count }
    }

    static func loadHistory() -> [DictationRecord] {
        let dir = Paths.history
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        var out: [DictationRecord] = []
        for f in files {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      (o["app"] as? String) != "selftest", let ts = o["ts"] as? String else { continue }
                let date = iso.date(from: ts) ?? Self.localDate(ts) ?? Date.distantPast
                let timings = o["timings"] as? [String: Any]
                out.append(DictationRecord(id: o["id"] as? String ?? UUID().uuidString, date: date,
                                           app: o["app_name"] as? String ?? "", duration: o["duration"] as? Double ?? 0,
                                           text: o["text"] as? String ?? "", wait: timings?["after_release"] as? Double))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    private static func localDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)
    }

    // MARK: edits

    func addTerm(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        editLexicon { lex in
            var hot = (lex["hotwords"] as? [String]) ?? []
            hot.removeAll { $0 == t }
            lex["hotwords"] = [t] + hot
            var all = (lex["terms"] as? [Any]) ?? []
            all.removeAll { (($0 as? [String: Any])?["term"] as? String ?? $0 as? String) == t }
            lex["terms"] = [["term": t]] + all
        }
    }

    func removeTerm(_ term: String) {
        editLexicon { lex in
            lex["hotwords"] = ((lex["hotwords"] as? [String]) ?? []).filter { $0 != term }
            lex["terms"] = ((lex["terms"] as? [Any]) ?? []).filter {
                (($0 as? [String: Any])?["term"] as? String ?? $0 as? String) != term
            }
        }
    }

    func forget(_ item: LearnedItem) {
        guard var l = (try? JSONSerialization.jsonObject(with: Data(contentsOf: learnedURL))) as? [String: Any] else { return }
        l["corrections"] = ((l["corrections"] as? [[String: Any]]) ?? []).filter {
            !(($0["from"] as? String) == item.from && ($0["to"] as? String) == item.to)
        }
        write(l, to: learnedURL)
        reload()
    }

    private func editLexicon(_ change: (inout [String: Any]) -> Void) {
        var lex = (try? JSONSerialization.jsonObject(with: Data(contentsOf: lexiconURL))) as? [String: Any] ?? [:]
        change(&lex)
        write(lex, to: lexiconURL)
        reload()
    }

    private func write(_ obj: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Stats

struct Stats {
    let count: Int
    let minutes: Double
    let chars: Int
    let medianWait: Double?
    /// Typing at ~60 Chinese characters a minute, minus the time spent speaking.
    var savedMinutes: Double { max(0, Double(chars) / 60 - minutes) }

    init(_ rs: [DictationRecord]) {
        count = rs.count
        minutes = rs.reduce(0) { $0 + $1.duration } / 60
        chars = rs.reduce(0) { $0 + $1.text.count }
        let waits = rs.compactMap(\.wait).sorted()
        medianWait = waits.isEmpty ? nil : waits[waits.count / 2]
    }
}

func summaryText(records: [DictationRecord], learned: [LearnedItem]) -> String {
    let cal = Calendar.current
    let week = records.filter { $0.date > cal.date(byAdding: .day, value: -7, to: Date())! }
    guard !week.isEmpty else { return "这周还没有听写记录。按住右侧 ⌥ 说话试试。" }
    let s = Stats(week)
    var lines = ["这周你口述了 \(s.count) 次，共 \(s.chars) 字，录音 \(String(format: "%.0f", s.minutes)) 分钟，估计少打了 \(String(format: "%.0f", s.savedMinutes)) 分钟的字。"]
    let byApp = Dictionary(grouping: week, by: \.app).mapValues(\.count).sorted { $0.value > $1.value }
    if let top = byApp.first {
        lines.append("用得最多的是 \(top.key)（\(top.value) 次）" + (byApp.count > 1 ? "，其次是 \(byApp[1].key)（\(byApp[1].value) 次）。" : "。"))
    }
    if let w = s.medianWait { lines.append(String(format: "松手后平均等待 %.1f 秒。", w)) }
    let long = week.filter { $0.duration >= 40 }.count
    if long > 0 { lines.append("其中 \(long) 次是 40 秒以上的长口述，适合用整理后的分段和列表直接发出去。") }
    if !learned.isEmpty {
        let top = learned.prefix(3).map { "\($0.from) → \($0.to)" }.joined(separator: "、")
        lines.append("已经从你的手动修改里学会 \(learned.count) 处：\(top)。")
    } else {
        lines.append("还没有学到纠错：识别错了就直接在输入框里改掉，Kaikou 会记住。")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Views

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @State private var tab = Int(ProcessInfo.processInfo.environment["KAIKOU_DASHBOARD_TAB"] ?? "0") ?? 0

    var body: some View {
        TabView(selection: $tab) {
            OverviewView(store: store).tabItem { Text("概览") }.tag(0)
            VocabularyView(store: store).tabItem { Text("词库") }.tag(1)
            HistoryView(store: store).tabItem { Text("历史") }.tag(2)
            SettingsView().tabItem { Text("设置") }.tag(3)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { store.reload() }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit()).bold().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct OverviewView: View {
    @ObservedObject var store: DashboardStore

    private var daily: [(day: Date, chars: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: today)!
            let chars = store.records.filter { cal.isDate($0.date, inSameDayAs: d) }.reduce(0) { $0 + $1.text.count }
            return (d, chars)
        }
    }

    var body: some View {
        let cal = Calendar.current
        let today = Stats(store.records.filter { cal.isDateInToday($0.date) })
        let all = Stats(store.records)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    StatTile(title: "今天", value: "\(today.count) 次 · \(today.chars) 字")
                    StatTile(title: "全部", value: "\(all.count) 次 · \(all.chars) 字")
                    StatTile(title: "省下的打字时间", value: String(format: "%.0f 分钟", all.savedMinutes))
                    StatTile(title: "松手后等待（中位数）", value: all.medianWait.map { String(format: "%.1f 秒", $0) } ?? "—")
                }
                Text("最近 14 天每天的字数").font(.headline)
                Chart(daily, id: \.day) { item in
                    BarMark(x: .value("日期", item.day, unit: .day), y: .value("字数", item.chars))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 160)
                Text("分析总结").font(.headline)
                Text(summaryText(records: store.records, learned: store.learned))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct VocabularyView: View {
    @ObservedObject var store: DashboardStore
    @State private var query = ""
    @State private var newTerm = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("我的词汇（\(store.terms.count)）").font(.headline)
                Text("排在前面的会交给识别模型，全部交给整理模型。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("添加一个词，比如 Kafbat", text: $newTerm).onSubmit(add)
                    Button("添加", action: add)
                }
                TextField("搜索", text: $query)
                List {
                    ForEach(store.terms.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { t in
                        HStack {
                            Text(t)
                            Spacer()
                            Button { store.removeTerm(t) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("自动学会的（\(store.learned.count)）").font(.headline)
                Text("你手动改过的词。改过 2 次会自动替换，1 次作为提示。").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(store.learned) { item in
                        HStack {
                            Text("\(item.from) → \(item.to)")
                            Spacer()
                            Text("×\(item.count)").foregroundStyle(.secondary)
                            Button { store.forget(item) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 140)
                Text("纠错规则（\(store.rules.count)）").font(.headline)
                List {
                    ForEach(Array(store.rules.enumerated()), id: \.offset) { _, r in
                        Text("\(r.0) → \(r.1)").font(.callout)
                    }
                }
            }
        }
    }

    private func add() {
        store.addTerm(newTerm)
        newTerm = ""
    }
}

struct HistoryView: View {
    @ObservedObject var store: DashboardStore
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        List(store.records.prefix(300)) { r in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(fmt.string(from: r.date)).font(.caption.monospacedDigit())
                    Text(r.app).font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.0f 秒", r.duration)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制") { Paster.copy(r.text) }.buttonStyle(.borderless)
                }
                Text(r.text.isEmpty ? "（没有文字）" : r.text).lineLimit(3).textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
    }
}

final class DashboardWindow {
    private var window: NSWindow?
    private let store = DashboardStore()

    func show() {
        store.reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Kaikou"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: DashboardView(store: store))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
