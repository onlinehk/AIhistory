import SwiftUI
import Charts

enum StatsRange: String, CaseIterable, Identifiable {
    case days7 = "7 日"
    case days30 = "30 日"
    case days90 = "90 日"
    case all = "全部"

    var id: String { rawValue }

    /// First included day key, or nil for everything.
    var sinceKey: String? {
        let days: Int
        switch self {
        case .days7: days = 7
        case .days30: days = 30
        case .days90: days = 90
        case .all: return nil
        }
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
        return UsageKey.day(for: start)
    }
}

struct UsageRow: Identifiable {
    let id: String
    let label: String
    var detail: String? = nil
    var color: Color = .secondary
    var sessions = 0
    var usage = TokenUsage()
    var cost = 0.0
    var unpriced = false
}

struct DailyPoint: Identifiable {
    var id: String { "\(day)-\(agent.rawValue)" }
    let day: Date
    let agent: Agent
    var cost: Double
    var tokens: Int
}

/// Totals for a set of sessions within a date range, priced with one table for both agents.
struct StatsData {
    var sessionCount = 0
    var promptCount = 0
    var usage = TokenUsage()
    var cost = 0.0
    var byModel: [UsageRow] = []
    var bySource: [UsageRow] = []
    var byProject: [UsageRow] = []
    var topSessions: [(session: SessionSummary, cost: Double, usage: TokenUsage)] = []
    var daily: [DailyPoint] = []
    var unpricedModels: [String] = []

    @MainActor
    init(sessions: [SessionSummary], prices: PriceBook, range: StatsRange) {
        let since = range.sinceKey
        var models: [String: UsageRow] = [:]
        var modelSessions: [String: Set<String>] = [:]
        var sources: [SessionSource: UsageRow] = [:]
        var projects: [String: UsageRow] = [:]
        var days: [String: DailyPoint] = [:]
        var unpriced = Set<String>()

        for s in sessions {
            let entries = s.usage.filter { since == nil || $0.key.day >= since! }
            let active = !entries.isEmpty || (since == nil || UsageKey.day(for: s.sortDate) >= since!)
            guard active else { continue }

            var sessionUsage = TokenUsage()
            var sessionCost = 0.0
            for (key, u) in entries {
                let c = prices.cost(u, model: key.model)
                if c == nil { unpriced.insert(key.model) }
                sessionUsage += u
                sessionCost += c ?? 0

                var row = models[key.model] ?? UsageRow(id: key.model, label: key.model, color: s.agent.color)
                row.usage += u
                row.cost += c ?? 0
                row.unpriced = c == nil
                row.detail = s.agent.label
                models[key.model] = row
                modelSessions[key.model, default: []].insert(s.id)

                if let date = UsageKey.date(forDay: key.day) {
                    let dk = "\(key.day)-\(s.agent.rawValue)"
                    var p = days[dk] ?? DailyPoint(day: date, agent: s.agent, cost: 0, tokens: 0)
                    p.cost += c ?? 0
                    p.tokens += u.total
                    days[dk] = p
                }
            }

            sessionCount += 1
            promptCount += s.promptCount
            usage += sessionUsage
            cost += sessionCost

            var src = sources[s.source] ?? UsageRow(id: s.source.rawValue, label: "\(s.agent.label) · \(s.source.label)", color: s.source.color)
            src.sessions += 1
            src.usage += sessionUsage
            src.cost += sessionCost
            sources[s.source] = src

            var proj = projects[s.projectPath] ?? UsageRow(id: s.projectPath, label: s.projectName, detail: s.projectPath)
            proj.sessions += 1
            proj.usage += sessionUsage
            proj.cost += sessionCost
            projects[s.projectPath] = proj

            if !sessionUsage.isEmpty { topSessions.append((s, sessionCost, sessionUsage)) }
        }

        for (model, ids) in modelSessions { models[model]?.sessions = ids.count }
        byModel = models.values.sorted { ($0.cost, $0.usage.total) > ($1.cost, $1.usage.total) }
        bySource = sources.values.sorted { ($0.cost, $0.sessions) > ($1.cost, $1.sessions) }
        byProject = Array(projects.values.sorted { ($0.cost, $0.usage.total) > ($1.cost, $1.usage.total) }.prefix(10))
        topSessions = Array(topSessions.sorted { ($0.cost, $0.usage.total) > ($1.cost, $1.usage.total) }.prefix(10))
        daily = days.values.sorted { $0.day < $1.day }
        unpricedModels = unpriced.sorted()
    }
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func usd(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(v > 0 && v < 1 ? 3 : 2)))
    }

    static func percent(_ v: Double) -> String {
        v.formatted(.percent.precision(.fractionLength(0)))
    }
}

struct StatsDashboard: View {
    let title: String
    let sessions: [SessionSummary]
    let onSelect: (SessionSummary) -> Void

    @AppStorage("statsRange") private var range: StatsRange = .days30
    @AppStorage("statsMetric") private var metric = "cost"
    private let prices = PriceBook.shared

    var body: some View {
        let data = StatsData(sessions: sessions, prices: prices, range: range)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                tiles(data)
                tokenBreakdown(data)
                chart(data)
                table(title: "按模型", rows: data.byModel, showSessions: true)
                table(title: "按來源", rows: data.bySource, showSessions: true)
                projects(data)
                topSessions(data)
                footnote(data)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("統計")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("統計").font(.largeTitle.bold())
                Text(title).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("時間", selection: $range) {
                ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
    }

    // MARK: Tiles

    private func tiles(_ d: StatsData) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            tile("估算費用", Fmt.usd(d.cost), "按 API 牌價", symbol: "dollarsign.circle")
            tile("Tokens", Fmt.tokens(d.usage.total), "輸入 \(Fmt.tokens(d.usage.allInput)) · 輸出 \(Fmt.tokens(d.usage.output))", symbol: "number")
            tile("Cache 命中率", Fmt.percent(d.usage.cacheHitRate), "輸入中由 cache 讀取嘅比例", symbol: "bolt.horizontal")
            tile("對話", "\(d.sessionCount)", "\(d.promptCount) 次提問", symbol: "bubble.left.and.bubble.right")
            tile("平均每個對話", d.sessionCount > 0 ? Fmt.usd(d.cost / Double(d.sessionCount)) : "–",
                 d.sessionCount > 0 ? "\(Fmt.tokens(d.usage.total / d.sessionCount)) tokens" : "", symbol: "divide.circle")
            tile("平均每次提問", d.promptCount > 0 ? Fmt.usd(d.cost / Double(d.promptCount)) : "–",
                 d.promptCount > 0 ? "\(Fmt.tokens(d.usage.total / d.promptCount)) tokens" : "", symbol: "text.bubble")
        }
    }

    private func tile(_ title: String, _ value: String, _ caption: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Token breakdown

    private func tokenBreakdown(_ d: StatsData) -> some View {
        let parts: [(String, Int, Color)] = [
            ("輸入（冇 cache）", d.usage.input, .blue),
            ("Cache 讀取", d.usage.cacheRead, .teal),
            ("Cache 寫入", d.usage.cacheWrite, .purple),
            ("輸出", d.usage.output, .orange),
        ]
        let total = max(d.usage.total, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Token 組成").font(.headline)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2.gradient)
                            .frame(width: max(0, geo.size.width * CGFloat(part.1) / CGFloat(total)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            HStack(spacing: 16) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.2).frame(width: 8, height: 8)
                        Text(part.0).foregroundStyle(.secondary)
                        Text(Fmt.tokens(part.1)).monospacedDigit()
                        Text("(\(Fmt.percent(Double(part.1) / Double(total))))").foregroundStyle(.tertiary)
                    }
                }
                if d.usage.reasoning > 0 {
                    Text("輸出入面 \(Fmt.tokens(d.usage.reasoning)) 係推理").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        }
    }

    // MARK: Chart

    private func chart(_ d: StatsData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("每日用量").font(.headline)
                Spacer()
                Picker("", selection: $metric) {
                    Text("費用").tag("cost")
                    Text("Tokens").tag("tokens")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            if d.daily.isEmpty {
                Text("呢段時間冇用量").foregroundStyle(.secondary).frame(height: 180)
            } else {
                Chart(d.daily) { p in
                    BarMark(
                        x: .value("日期", p.day, unit: .day),
                        y: .value(metric == "cost" ? "費用" : "Tokens", metric == "cost" ? p.cost : Double(p.tokens))
                    )
                    .foregroundStyle(by: .value("Agent", p.agent.label))
                }
                .chartForegroundStyleScale(["Claude Code": Agent.claude.color, "Codex": Agent.codex.color])
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(metric == "cost" ? Fmt.usd(v) : Fmt.tokens(Int(v)))
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
        }
    }

    // MARK: Tables

    private func table(title: String, rows: [UsageRow], showSessions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    if showSessions { Text("對話") }
                    Text("輸入")
                    Text("Cache 讀")
                    Text("Cache 寫")
                    Text("輸出")
                    Text("費用")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(row.color).frame(width: 8, height: 8)
                            Text(row.label).lineLimit(1)
                            if let detail = row.detail, detail != row.label, title == "按模型" {
                                Text(detail).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        if showSessions { Text("\(row.sessions)") }
                        Text(Fmt.tokens(row.usage.input))
                        Text(Fmt.tokens(row.usage.cacheRead))
                        Text(Fmt.tokens(row.usage.cacheWrite))
                        Text(Fmt.tokens(row.usage.output))
                        if row.unpriced {
                            Text("未定價").foregroundStyle(.orange)
                        } else {
                            Text(Fmt.usd(row.cost)).fontWeight(.medium)
                        }
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
        }
    }

    private func projects(_ d: StatsData) -> some View {
        let maxCost = d.byProject.map(\.cost).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("最多用量嘅專案").font(.headline)
            ForEach(d.byProject) { row in
                HStack(spacing: 10) {
                    Text(row.label).lineLimit(1).frame(width: 220, alignment: .leading).help(row.detail ?? "")
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.gradient)
                            .frame(width: maxCost > 0 ? geo.size.width * row.cost / maxCost : 0)
                    }
                    .frame(height: 10)
                    Text("\(row.sessions) 個對話").foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    Text(Fmt.tokens(row.usage.total)).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    Text(Fmt.usd(row.cost)).frame(width: 80, alignment: .trailing)
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
    }

    private func topSessions(_ d: StatsData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最貴嘅對話").font(.headline)
            ForEach(d.topSessions, id: \.session.id) { item in
                Button {
                    onSelect(item.session)
                } label: {
                    HStack(spacing: 8) {
                        SourceBadge(source: item.session.source)
                        Text(item.session.title).lineLimit(1)
                        Text(item.session.projectName).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Text(Fmt.tokens(item.usage.total)).foregroundStyle(.secondary)
                        Text(Fmt.usd(item.cost)).frame(width: 80, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .monospacedDigit()
            }
        }
    }

    private func footnote(_ d: StatsData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !d.unpricedModels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("未有價錢、冇計入費用：\(d.unpricedModels.joined(separator: "、"))")
                    SettingsLink { Text("設定價錢…") }
                }
            }
            Text("費用 = 每個模型嘅 token × API 牌價（Claude 同 Codex 用同一套計法：冇 cache 嘅輸入、cache 讀取、cache 寫入、輸出分開計）。如果你用 Claude Pro / Max 或者 ChatGPT Plus / Pro 訂閱，實際收費唔係咁計，呢個數只係 API 等價，方便比較。可以喺「設定」(⌘,) 改價錢。")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}
