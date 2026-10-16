import SwiftUI

struct TranscriptView: View {
    let session: SessionSummary
    let onDelete: () -> Void

    @State private var items: [TranscriptItem] = []
    @State private var isLoading = true
    @AppStorage("showTools") private var showTools = true
    @AppStorage("showThinking") private var showThinking = false

    private var allAttachments: [Attachment] {
        items.flatMap(\.attachments)
    }

    private var visibleItems: [TranscriptItem] {
        items.filter { item in
            switch item.kind {
            case .tool: return showTools
            case .thinking: return showThinking
            default: return true
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if visibleItems.isEmpty {
                    Text("呢個對話冇內容").foregroundStyle(.secondary).padding(40)
                } else {
                    ForEach(visibleItems) { item in
                        TranscriptItemView(item: item, agent: session.agent, projectPath: session.projectPath)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
        .navigationTitle(session.title)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showTools) {
                    Label("工具調用", systemImage: "wrench.and.screwdriver")
                }
                .help("顯示 / 隱藏工具調用")
                Toggle(isOn: $showThinking) {
                    Label("思考過程", systemImage: "brain")
                }
                .help("顯示 / 隱藏 thinking")
                Menu {
                    Button("複製 resume 指令") { Clipboard.copy(session.resumeCommand) }
                    Button("複製 Session ID") { Clipboard.copy(session.sessionId) }
                    Button("複製成 Markdown") { Clipboard.copy(markdownExport()) }
                    Divider()
                    let attachments = allAttachments.filter(\.isAvailable)
                    Button("下載所有附件 (\(attachments.count))…") {
                        AttachmentActions.save(attachments, folderName: session.title)
                    }
                    .disabled(attachments.isEmpty)
                    Divider()
                    Button("喺 Finder 顯示 .jsonl") {
                        NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
                    }
                    Button("開啟專案資料夾") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
                    }
                    Divider()
                    Button("移去垃圾桶…", role: .destructive, action: onDelete)
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                Button(action: onDelete) {
                    Label("刪除", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .help("移去垃圾桶 (⌘⌫)")
            }
        }
        .task(id: session.modified) {
            let url = session.fileURL
            let agent = session.agent
            let base = session.projectPath
            let loaded = await Task.detached(priority: .userInitiated) {
                var items = agent == .codex ? CodexParser.transcript(url) : HistoryParser.transcript(url)
                LocalLinks.attachLinkedFiles(to: &items, base: base)
                return items
            }.value
            items = loaded
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SourceBadge(source: session.source)
                Text(session.title).font(.title2.weight(.semibold))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                meta("專案", session.projectPath)
                if let branch = session.gitBranch { meta("分支", branch) }
                if let start = session.startDate {
                    let range = session.endDate.map { end in
                        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
                        return "\(start.formatted(date: .abbreviated, time: .shortened)) → \(end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))"
                    }
                    meta("時間", range ?? start.formatted())
                }
                meta("來源", "\(session.agent.label) · \(session.source.label)" + (session.rawEntrypoint.map { "  (\($0))" } ?? ""))
                if let model = session.model { meta("模型", model) }
                let usage = session.totalUsage
                if !usage.isEmpty {
                    meta("Tokens", "\(Fmt.tokens(usage.total))（輸入 \(Fmt.tokens(usage.input)) · cache 讀 \(Fmt.tokens(usage.cacheRead)) · cache 寫 \(Fmt.tokens(usage.cacheWrite)) · 輸出 \(Fmt.tokens(usage.output))）")
                    let prices = PriceBook.shared
                    let unpriced = prices.unpricedModels(in: session)
                    meta("估算費用", Fmt.usd(prices.cost(of: session))
                         + (session.usageByModel.count > 1 ? "（" + session.usageByModel.sorted { $0.value.total > $1.value.total }
                            .map { "\($0.key) \(prices.cost($0.value, model: $0.key).map(Fmt.usd) ?? "未定價")" }
                            .joined(separator: "、") + "）" : "")
                         + (unpriced.isEmpty || session.usageByModel.count > 1 ? "" : "（\(unpriced.joined(separator: "、")) 未定價）"))
                }
                if let v = session.version { meta("版本", "\(session.agent.label) \(v)") }
                meta("Session", session.sessionId)
            }
            .font(.callout)
        }
    }

    private func meta(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).lineLimit(2)
        }
    }

    private func markdownExport() -> String {
        var out = "# \(session.title)\n\n"
        for item in items {
            switch item.kind {
            case .user: out += "## 🧑 User\n\n\(item.text)\n\n"
            case .assistant: out += "## 🤖 \(session.agent == .codex ? "Codex" : "Claude")\n\n\(item.text)\n\n"
            case .tool: out += "> 🔧 \(item.title ?? "") \(item.text)\n\n"
            case .system: out += "> \(item.text)\n\n"
            case .thinking: break
            }
        }
        return out
    }
}

struct TranscriptItemView: View {
    let item: TranscriptItem
    let agent: Agent
    let projectPath: String

    var body: some View {
        switch item.kind {
        case .user: userBubble
        case .assistant: assistantBlock
        case .thinking: thinkingBlock
        case .tool: ToolCallView(item: item)
        case .system: systemLine
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                if !item.context.isEmpty || item.imageCount > 0 {
                    HStack(spacing: 4) {
                        ForEach(item.context, id: \.self) { chip($0, symbol: "doc.text") }
                        if item.imageCount > 0 { chip("\(item.imageCount) 張圖（已不存在）", symbol: "photo") }
                    }
                }
                if !item.attachments.isEmpty {
                    AttachmentsView(attachments: item.attachments, alignment: .trailing)
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }
                if let date = item.date {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var assistantBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: agent.symbol)
                .foregroundStyle(agent.color)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                MarkdownView(text: item.text, baseDirectory: projectPath)
                if !item.attachments.isEmpty {
                    AttachmentsView(attachments: item.attachments)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var thinkingBlock: some View {
        DisclosureGroup {
            Text(item.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("思考過程", systemImage: "brain").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.leading, 28)
    }

    private var systemLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let detail = item.toolResult {
                DisclosureGroup {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(item.text).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(item.text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(item.isError ? Color.red : Color.secondary)
                    .lineLimit(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 28)
    }
}

struct ToolCallView: View {
    let item: TranscriptItem
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let input = item.toolInput, input != "{\n\n}" {
                    codeBox(input, caption: "Input")
                }
                if let result = item.toolResult, !result.isEmpty {
                    codeBox(result, caption: item.isError ? "Error" : "Result")
                }
                if !item.attachments.isEmpty {
                    AttachmentsView(attachments: item.attachments)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                    .foregroundStyle(item.isError ? .red : .secondary)
                Text(item.title ?? "tool").font(.callout.weight(.medium))
                if !item.attachments.isEmpty {
                    Label("\(item.attachments.count)", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 28)
    }

    private func codeBox(_ text: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
