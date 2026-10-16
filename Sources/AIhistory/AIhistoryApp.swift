import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        migrateSettingsFromOldName()
        // `AIhistory --dump` prints the index to stdout (handy for checking the parser).
        if CommandLine.arguments.contains("--dump") {
            let claude = HistoryParser.sessionFiles().compactMap(HistoryParser.summarize)
            let codex = CodexParser.sessionFiles().compactMap(CodexParser.summarize)
            for s in (claude + codex).sorted(by: { $0.sortDate > $1.sortDate }) {
                let items = s.agent == .codex ? CodexParser.transcript(s.fileURL) : HistoryParser.transcript(s.fileURL)
                print("[\(s.source.shortLabel)] \(s.projectName) | \(s.title) | prompts=\(s.promptCount) items=\(items.count) attachments=\(items.reduce(0) { $0 + $1.attachments.count }) missing=\(items.reduce(0) { $0 + $1.imageCount })")
            }
            return
        }
        // `AIhistory --stats` prints per-session usage and cost (for checking the numbers).
        if CommandLine.arguments.contains("--stats") {
            MainActor.assumeIsolated {
                let prices = PriceBook.shared
                let all = HistoryParser.sessionFiles().compactMap(HistoryParser.summarize)
                    + CodexParser.sessionFiles().compactMap(CodexParser.summarize)
                for s in all {
                    let u = s.totalUsage
                    print("\(s.agent.rawValue)\t\(s.isSubagent ? "sub" : "main")\t\(s.sessionId)\t\(String(format: "%.4f", prices.cost(of: s)))\t\(u.input)\t\(u.cacheRead)\t\(u.cacheWrite5m)\t\(u.cacheWrite1h)\t\(u.output)\t\(prices.unpricedModels(in: s).joined(separator: ","))")
                }
            }
            return
        }
        AIhistoryApp.main()
    }
}

/// The app used to be "Claude History" (bundle id local.claude-history); copy its saved settings once.
private func migrateSettingsFromOldName() {
    let defaults = UserDefaults.standard
    let flag = "migratedFromClaudeHistory"
    guard !defaults.bool(forKey: flag) else { return }
    defaults.set(true, forKey: flag)
    guard let old = UserDefaults(suiteName: "local.claude-history") else { return }
    for key in ["priceOverrides", "showTools", "showThinking", "statsRange", "statsMetric"]
    where defaults.object(forKey: key) == nil {
        if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
    }
}

struct AIhistoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("AIhistory") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            TabView {
                PriceSettingsView()
                    .tabItem { Label("價錢表", systemImage: "dollarsign.circle") }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle) so the window gets focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @State private var store = HistoryStore()
    @State private var filter: SourceFilter? = .all
    @State private var project: String?
    @State private var selection = Set<SessionSummary.ID>()
    @State private var pendingDelete: [SessionSummary] = []
    @State private var deleteError: String?
    @State private var query = ""
    @Environment(\.scenePhase) private var scenePhase

    private var visibleSessions: [SessionSummary] {
        store.filtered(filter ?? .all, project: project, query: query)
    }

    private var selectedSessions: [SessionSummary] {
        store.sessions.filter { selection.contains($0.id) }
    }

    private func requestDelete(_ sessions: [SessionSummary]) {
        if !sessions.isEmpty { pendingDelete = sessions }
    }

    private func performDelete() {
        let targets = pendingDelete
        pendingDelete = []
        let failures = store.trash(targets)
        selection.subtract(targets.map(\.id))
        selection.formUnion(failures.map { $0.0.id })
        if !failures.isEmpty {
            deleteError = failures.map { "\($0.0.title): \($0.1.localizedDescription)" }.joined(separator: "\n")
        }
    }

    private var deleteMessage: String {
        var text = "會將 .jsonl 紀錄同相關嘅 tool-results、file-history 一齊移去垃圾桶，可以喺 Finder 垃圾桶還原。"
        if pendingDelete.contains(where: { $0.agent == .codex }) {
            text += "\n\nCodex App 有自己嘅資料庫，刪咗 rollout 檔之後佢側邊欄可能仍然見到個 thread，但打開會冇內容。"
        }
        if pendingDelete.contains(where: { Date().timeIntervalSince($0.modified) < 120 }) {
            text += "\n\n⚠️ 其中有對話兩分鐘內仲有更新，可能仲開緊，刪咗之後 Claude 可能會再寫入。"
        }
        return text
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, filter: $filter)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            SessionListView(
                store: store,
                sessions: visibleSessions,
                filter: filter ?? .all,
                project: $project,
                selection: $selection,
                onDelete: requestDelete
            )
            .searchable(text: $query, placement: .sidebar, prompt: "搜尋標題 / 內容")
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 560)
        } detail: {
            let selected = selectedSessions
            if selected.count == 1, let session = selected.first {
                TranscriptView(session: session, onDelete: { requestDelete([session]) })
                    .id(session.id)
            } else if selected.count > 1 {
                ContentUnavailableView {
                    Label("已揀 \(selected.count) 個對話", systemImage: "square.stack")
                } actions: {
                    Button(role: .destructive) {
                        requestDelete(selected)
                    } label: {
                        Label("移去垃圾桶", systemImage: "trash")
                    }
                }
            } else {
                StatsDashboard(
                    title: (filter ?? .all).title + (project.map { " · \(($0 as NSString).lastPathComponent)" } ?? "")
                        + (query.isEmpty ? "" : " · 搜尋「\(query)」"),
                    sessions: visibleSessions,
                    onSelect: { selection = [$0.id] }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selection = []
                } label: {
                    Label("統計", systemImage: "chart.bar.xaxis")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("睇目前篩選嘅統計 (⇧⌘S)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.reload()
                } label: {
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("重新整理", systemImage: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("重新讀取 ~/.claude/projects (⌘R)")
            }
        }
        .confirmationDialog(
            pendingDelete.count == 1 ? "刪除「\(pendingDelete[0].title)」？" : "刪除 \(pendingDelete.count) 個對話？",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button("移去垃圾桶", role: .destructive, action: performDelete)
            Button("取消", role: .cancel) { pendingDelete = [] }
        } message: {
            Text(deleteMessage)
        }
        .alert("有啲對話刪唔到", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .onAppear { store.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reload() }
        }
        .onChange(of: filter) { _, _ in
            // Drop the project filter if it has no sessions under the new source.
            if let project, !store.projects(for: filter ?? .all).contains(where: { $0.path == project }) {
                self.project = nil
            }
        }
    }
}
