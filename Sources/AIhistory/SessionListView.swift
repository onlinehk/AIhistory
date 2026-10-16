import SwiftUI

struct SessionListView: View {
    let store: HistoryStore
    let sessions: [SessionSummary]
    let filter: SourceFilter
    @Binding var project: String?
    @Binding var selection: Set<SessionSummary.ID>
    let onDelete: ([SessionSummary]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            projectPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()

            if sessions.isEmpty {
                if store.isLoading && store.sessions.isEmpty {
                    ProgressView("讀取緊…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("冇對話", systemImage: "tray", description: Text("試吓轉來源或者清除搜尋"))
                }
            } else {
                List(selection: $selection) {
                    ForEach(grouped, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { s in
                                SessionRow(session: s, showProject: project == nil)
                                    .tag(s.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: SessionSummary.ID.self) { ids in
                    contextMenu(for: sessions.filter { ids.contains($0.id) })
                }
                .onDeleteCommand {
                    onDelete(sessions.filter { selection.contains($0.id) })
                }
            }
        }
        .navigationTitle(filter.title)
        .navigationSubtitle("\(sessions.count) 個對話")
    }

    private var projectPicker: some View {
        Picker(selection: $project) {
            Text("所有專案").tag(String?.none)
            Divider()
            ForEach(store.projects(for: filter), id: \.path) { p in
                Text("\(p.name)  (\(p.count))").tag(Optional(p.path))
            }
        } label: {
            Image(systemName: "folder")
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func contextMenu(for targets: [SessionSummary]) -> some View {
        if targets.count == 1, let s = targets.first {
            Button("複製 resume 指令") { Clipboard.copy(s.resumeCommand) }
            Button("複製 Session ID") { Clipboard.copy(s.sessionId) }
            Divider()
        }
        if !targets.isEmpty {
            Button("喺 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.fileURL)) }
            Divider()
            Button(targets.count == 1 ? "移去垃圾桶…" : "將 \(targets.count) 個對話移去垃圾桶…", role: .destructive) {
                onDelete(targets)
            }
        }
    }

    private struct Group {
        let title: String
        let items: [SessionSummary]
    }

    /// Buckets: 今日 / 昨日 / 過去 7 日 / then by month.
    private var grouped: [Group] {
        let cal = Calendar.current
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday)!
        let startWeek = cal.date(byAdding: .day, value: -7, to: startToday)!
        let monthFormat = Date.FormatStyle().year().month(.wide)

        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]
        for s in sessions {
            let d = s.sortDate
            let key: String
            if d >= startToday { key = "今日" }
            else if d >= startYesterday { key = "昨日" }
            else if d >= startWeek { key = "過去 7 日" }
            else { key = d.formatted(monthFormat) }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(s)
        }
        return order.map { Group(title: $0, items: buckets[$0]!) }
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let showProject: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.headline)
                .lineLimit(2)
            if !session.firstPrompt.isEmpty, session.firstPrompt != session.title {
                Text(session.firstPrompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                SourceBadge(source: session.source)
                if showProject {
                    Text(session.projectName)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                let cost = PriceBook.shared.cost(of: session)
                if cost > 0 {
                    Text(Fmt.usd(cost)).monospacedDigit().fixedSize()
                }
                Text(session.sortDate, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

struct SourceBadge: View {
    let source: SessionSource

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: source.symbol)
            Text(source.shortLabel)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(source.color)
        .background(source.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
    }
}

enum Clipboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

extension SessionSummary {
    var resumeCommand: String {
        let resume = agent == .codex ? "codex resume \(sessionId)" : "claude --resume \(sessionId)"
        return "cd \(shellQuote(projectPath)) && \(resume)"
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
