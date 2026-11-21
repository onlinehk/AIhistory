import Charts
import SwiftUI

enum OpenRouterMoney {
    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...8)))
    }

    static func amount(_ value: Double?) -> String {
        value.map(usd) ?? "–"
    }
}

private struct OpenRouterMetrics: View {
    let items: [(label: String, value: String)]
    var columns = 4

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(items, id: \.label) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.label).font(.callout).foregroundStyle(.secondary)
                    Text(item.value).font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct OpenRouterReportStatus<Value>: View {
    let report: OpenRouterReport<Value>

    var body: some View {
        if let error = report.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        }
        if report.isLoading {
            ProgressView().controlSize(.small)
        } else if let updated = report.updatedAt {
            Text("更新於 \(updated.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OpenRouterSettingsView: View {
    private let store = OpenRouterStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OpenRouterCredentialField(credential: .api,
                                      explanation: "讀取單一 key 嘅用量、上限同指定 generation 嘅收費。")
            Divider()
            OpenRouterCredentialField(credential: .management,
                                      explanation: "讀取 Activity 明細。查帳戶 credits 需要有相關權限嘅帳戶層級 key，可用唯讀 key。")
            Link("OpenRouter Management Keys ↗", destination: URL(string: "https://openrouter.ai/settings/management-keys")!)
            Text("兩條 key 分開儲存喺 macOS Keychain。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("清除呢條 API key 嘅本機走勢紀錄") { store.clearHistory() }
                .disabled(store.snapshots.isEmpty || store.keyInfo.isLoading)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 720, height: 520, alignment: .topLeading)
    }
}

private struct OpenRouterCredentialField: View {
    let credential: OpenRouterCredential
    let explanation: String
    private let store = OpenRouterStore.shared
    @State private var draft = ""
    @State private var storageError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(credential.label).font(.headline)
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField(store.hasKey(credential) ? "已儲存（可輸入新 key）" : "sk-or-v1-…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("儲存") { save(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if store.hasKey(credential) {
                    Button("測試連線") {
                        if credential == .api { store.refreshKey() } else { store.refreshManagement() }
                    }
                    Button("移除", role: .destructive) { save("") }
                }
            }
            if let storageError {
                Label(storageError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            if credential == .api {
                if store.keyInfo.value?.isManagementKey == true {
                    Text("呢條係 Management key，請放喺下面嘅 Management key 欄。")
                        .font(.callout).foregroundStyle(.orange)
                }
                OpenRouterReportStatus(report: store.keyInfo)
            } else {
                OpenRouterReportStatus(report: store.activity)
                if let error = store.credits.error, error != store.activity.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            }
        }
    }

    private func save(_ value: String) {
        do {
            try store.setKey(value, for: credential)
            draft = ""
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }
}

private struct OpenRouterKeySummary: View {
    let info: OpenRouterKeyInfo

    var body: some View {
        OpenRouterMetrics(items: [
            ("累計", OpenRouterMoney.amount(info.usage)),
            ("今日", OpenRouterMoney.amount(info.usageDaily)),
            ("本週", OpenRouterMoney.amount(info.usageWeekly)),
            ("本月", OpenRouterMoney.amount(info.usageMonthly)),
        ])
        if let limit = info.limit {
            Text("Key 額度剩餘 \(OpenRouterMoney.amount(info.limitRemaining)) · 上限 \(OpenRouterMoney.usd(limit))"
                 + (info.limitReset.map { " · \($0) 重置" } ?? ""))
                .font(.callout)
        }
        if let byok = info.byokUsage, byok > 0 {
            Text("BYOK 用量估算 · 累計 \(OpenRouterMoney.usd(byok)) · 今日 \(OpenRouterMoney.amount(info.byokUsageDaily)) · 本週 \(OpenRouterMoney.amount(info.byokUsageWeekly)) · 本月 \(OpenRouterMoney.amount(info.byokUsageMonthly))")
                .font(.caption).foregroundStyle(.secondary)
        }
        if info.isFreeTier == true { Text("方案 · Free tier").font(.caption).foregroundStyle(.secondary) }
    }
}

struct OpenRouterSection: View {
    let range: StatsRange
    let allSources: Bool
    private let store = OpenRouterStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OpenRouter").font(.headline)
                Spacer()
                Button("詳細統計與計費") { openWindow(id: OpenRouterDetailView.windowID) }
            }
            if allSources {
                accountSummary
            } else {
                keySummary
            }
        }
        .onChange(of: allSources, initial: true) { _, allSources in
            if allSources { store.refreshManagement(ifStale: true) } else { store.refreshKey(ifStale: true) }
        }
    }

    @ViewBuilder private var accountSummary: some View {
        if store.hasKey(.management) {
            let credits = store.credits.value
            let activity = store.activity.value
            OpenRouterMetrics(items: [
                ("帳戶累計扣費", OpenRouterMoney.amount(credits?.totalUsage)),
                ("帳戶 credits 餘額", OpenRouterMoney.amount(credits?.remaining)),
                (activity?.includesToday == false ? "已完結 30 日扣費" : "最近 30 日扣費", OpenRouterMoney.amount(activity?.spend(days: 30))),
                ("今日扣費（UTC）", OpenRouterMoney.amount(activity?.todaySpend)),
            ])
            Text("近期用量涵蓋 Management key 可見嘅所有 API keys，按 UTC 計。")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = activity?.notice {
                Label("\(notice)。今日用量未計入。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            OpenRouterReportStatus(report: store.activity)
            if store.credits.error != store.activity.error, let error = store.credits.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } else {
            AppSettingsLink(tab: .openRouter) { Text("設定 Management key 以睇整體用量…") }
        }
    }

    @ViewBuilder private var keySummary: some View {
        if let info = store.keyInfo.value, info.isManagementKey != true {
            OpenRouterKeySummary(info: info)
            let points = store.dailySpend(since: range.sinceKey)
            if !points.isEmpty {
                Chart(points) { point in
                    BarMark(x: .value("日期", point.day, unit: .day), y: .value("費用", point.cost))
                        .foregroundStyle(Color.indigo.gradient)
                }
                .frame(height: 140)
                Text("走勢按本機快照差值計，間隔期間嘅用量歸入下次記錄。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("單一 API key 用量 · 今日、本週同本月按 UTC")
                .font(.caption).foregroundStyle(.secondary)
        } else if !store.hasKey(.api) && !store.hasKey(.management) {
            AppSettingsLink(tab: .openRouter) { Text("設定 OpenRouter keys…") }
        }
        OpenRouterReportStatus(report: store.keyInfo)
    }
}

struct OpenRouterDetailView: View {
    static let windowID = "openrouter-details"
    private let generationSection = "generation"

    private let store = OpenRouterStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accountCredits
                    Divider()
                    dailyActivity
                    if store.hasKey(.api) {
                        Divider()
                        keyUsage
                    }
                    Divider()
                    OpenRouterGenerationView().id(generationSection)
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.generation.updatedAt) { _, updated in
                if updated != nil {
                    withAnimation { scroll.scrollTo(generationSection, anchor: .bottom) }
                }
            }
        }
        .toolbar {
            Button {
                store.refreshKey()
                store.refreshManagement()
            } label: {
                Label("重新整理 OpenRouter", systemImage: "arrow.clockwise")
            }
            .disabled(!store.hasKey(.api) && !store.hasKey(.management))
            AppSettingsLink(tab: .openRouter) { Image(systemName: "gear").accessibilityLabel("設定 OpenRouter") }
        }
        .onAppear {
            store.refreshKey(ifStale: true)
            store.refreshManagement(ifStale: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshKey(ifStale: true)
                store.refreshManagement(ifStale: true)
            }
        }
    }

    private var accountCredits: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("帳戶 credits").font(.title2.bold())
                Spacer()
                Link("OpenRouter 帳單 ↗", destination: URL(string: "https://openrouter.ai/settings/credits")!)
            }
            if let credits = store.credits.value {
                OpenRouterMetrics(items: [
                    ("剩餘", OpenRouterMoney.usd(credits.remaining)),
                    ("已使用", OpenRouterMoney.usd(credits.totalUsage)),
                    ("累計購買", OpenRouterMoney.usd(credits.totalCredits)),
                ], columns: 3)
            }
            if !store.hasKey(.management) {
                AppSettingsLink(tab: .openRouter) { Text("設定 Management key 以讀取餘額…") }
            }
            OpenRouterReportStatus(report: store.credits)
        }
    }

    private var dailyActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("用量及收費明細").font(.title2.bold())
                Spacer()
                Link("OpenRouter Activity ↗", destination: URL(string: "https://openrouter.ai/activity")!)
            }
            if let snapshot = store.activity.value {
                OpenRouterActivityView(snapshot: snapshot)
            } else if !store.hasKey(.management) {
                Text("加入 Management key 就可以睇每日、每個模型同供應商嘅用量。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            OpenRouterReportStatus(report: store.activity)
        }
    }

    private var keyUsage: some View {
        VStack(alignment: .leading, spacing: 10) {
            let label = store.keyInfo.value?.label
            Text("單一 API key 用量" + (label.map { " · \($0)" } ?? "")).font(.title2.bold())
            if let info = store.keyInfo.value, info.isManagementKey != true {
                OpenRouterKeySummary(info: info)
                Text("今日、本週同本月按 UTC。").font(.caption).foregroundStyle(.secondary)
            }
            OpenRouterReportStatus(report: store.keyInfo)
        }
    }
}

private struct OpenRouterActivityView: View {
    let snapshot: OpenRouterActivitySnapshot
    @State private var days = 30
    @State private var group = Group.model
    @State private var query = ""

    private enum Group: String, CaseIterable {
        case model = "按模型"
        case provider = "按供應商"
        case day = "按日"

        func name(for row: OpenRouterActivity) -> String {
            switch self {
            case .model: row.model.isEmpty ? "未提供模型" : row.model
            case .provider: row.providerName.flatMap { $0.isEmpty ? nil : $0 } ?? "未提供供應商"
            case .day: row.date
            }
        }
    }

    var body: some View {
        let period = snapshot.period(days: days)
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = period.rows(from: snapshot.rows).filter { row in
            search.isEmpty || row.model.localizedStandardContains(search)
                || (row.providerName?.localizedStandardContains(search) ?? false)
        }
        let total = rows.reduce(into: OpenRouterUsage()) { $0.add($1) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("UTC 時段", selection: $days) {
                    Text("7 日").tag(7)
                    Text("30 日").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                Text("\(period.days.first ?? "") 至 \(period.days.last ?? "") · UTC")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                TextField("搜尋模型或供應商", text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            if let notice = snapshot.notice {
                Label("\(notice)。目前顯示已完結嘅 UTC 日，今日用量未計入。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Management key 可見範圍 · 包括今日截至查詢時嘅 UTC 用量")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Text(search.isEmpty ? "呢段期間未有用量。" : "搵唔到符合搜尋嘅用量。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                OpenRouterMetrics(items: [
                    ("OpenRouter 扣費", OpenRouterMoney.usd(total.cost)),
                    ("請求", total.requests.formatted()),
                    ("輸入／輸出 tokens", "\(Fmt.tokens(total.prompt)) / \(Fmt.tokens(total.completion))"),
                    ("Cache 命中率", total.cacheHitRate.map(Fmt.percent) ?? "–"),
                ])
                chart(rows, days: period.days)
                Picker("分組", selection: $group) {
                    ForEach(Group.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                breakdown(rows)
                if total.hasPartialCache {
                    Text("Cache 命中率按有回報而且可比較嘅輸入 tokens 計。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("BYOK 係自備供應商 key 嘅推理費估算，另列於 OpenRouter 扣費旁。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chart(_ rows: [OpenRouterActivity], days: [String]) -> some View {
        let totals = rows.reduce(into: [String: Double]()) { $0[$1.date, default: 0] += $1.usage }
        let labels = days.enumerated().compactMap { index, day in
            index % (days.count > 7 ? 5 : 1) == 0 || day == days.last ? day : nil
        }
        let low = min(0, totals.values.min() ?? 0)
        let high = max(0, totals.values.max() ?? 0)
        return Chart(days, id: \.self) { day in
            BarMark(x: .value("日期 (UTC)", day), y: .value("OpenRouter 扣費", totals[day, default: 0]))
                .foregroundStyle(Color.indigo.gradient)
                .accessibilityLabel(day)
                .accessibilityValue(OpenRouterMoney.usd(totals[day, default: 0]))
        }
        .chartXScale(domain: days)
        .chartYScale(domain: low...(low == high ? 1 : high))
        .chartXAxis {
            AxisMarks(values: labels) { item in
                AxisValueLabel { if let value = item.as(String.self) { Text(value.suffix(5)) } }
            }
        }
        .chartYAxis {
            AxisMarks { item in
                AxisGridLine()
                AxisValueLabel { if let cost = item.as(Double.self) { Text(OpenRouterMoney.usd(cost)) } }
            }
        }
        .frame(height: 150)
    }

    private func breakdown(_ rows: [OpenRouterActivity]) -> some View {
        let grouped = rows.reduce(into: [String: OpenRouterUsage]()) { $0[group.name(for: $1), default: OpenRouterUsage()].add($1) }
        let sorted = grouped.sorted { left, right in
            if group == .day { return left.key > right.key }
            if left.value.cost != right.value.cost { return left.value.cost > right.value.cost }
            if left.value.requests != right.value.requests { return left.value.requests > right.value.requests }
            return left.key < right.key
        }
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                GridRow {
                    Text(group.rawValue).frame(minWidth: 150, alignment: .leading)
                    Text("請求")
                    Text("輸入")
                    Text("輸出")
                    Text("推理")
                    Text("Cache 命中")
                    Text("OpenRouter 扣費")
                    Text("BYOK 估算")
                }
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(sorted, id: \.key) { key, usage in
                    GridRow {
                        Text(key).textSelection(.enabled)
                        Text(usage.requests.formatted())
                        Text(Fmt.tokens(usage.prompt))
                        Text(Fmt.tokens(usage.completion))
                        Text(Fmt.tokens(usage.reasoning))
                        Text(usage.cacheHitRate.map(Fmt.percent) ?? "–")
                        Text(OpenRouterMoney.usd(usage.cost)).fontWeight(.semibold)
                        Text(OpenRouterMoney.usd(usage.byok))
                    }
                }
            }
            .font(.callout).monospacedDigit()
        }
    }
}

private struct OpenRouterGenerationView: View {
    private let store = OpenRouterStore.shared
    @State private var draft = ""
    @State private var selectedCredential = OpenRouterCredential.api

    var body: some View {
        let available = OpenRouterCredential.allCases.filter(store.hasKey)
        let credential = available.contains(selectedCredential) ? selectedCredential : available.first
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("單次請求收費").font(.title2.bold())
                Spacer()
                Link("開啟 OpenRouter Logs ↗", destination: URL(string: "https://openrouter.ai/logs")!)
            }
            if let credential {
                HStack {
                    TextField("Generation ID（gen-…）", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.lookupGeneration(draft, with: credential) }
                    if available.count > 1 {
                        Picker("查詢用 key", selection: $selectedCredential) {
                            ForEach(available, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button("查詢") { store.lookupGeneration(draft, with: credential) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.generation.isLoading)
                }
                if let generation = store.generation.value {
                    generationDetails(generation)
                }
                OpenRouterReportStatus(report: store.generation)
            } else {
                AppSettingsLink(tab: .openRouter) { Text("設定 OpenRouter key 以查詢指定 generation…") }
            }
        }
    }

    private func generationDetails(_ generation: OpenRouterGeneration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text([generation.model, generation.providerName, generation.createdAt].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            Text(generation.id).font(.caption.monospaced()).textSelection(.enabled)
            OpenRouterMetrics(items: [
                ("OpenRouter 扣費", OpenRouterMoney.amount(generation.cost)),
                ("輸入 tokens", tokens(generation.nativeTokensPrompt ?? generation.tokensPrompt)),
                ("輸出 tokens", tokens(generation.nativeTokensCompletion ?? generation.tokensCompletion)),
                ("Cache tokens", tokens(generation.nativeTokensCached)),
            ])
            let details = [
                generation.nativeTokensReasoning.map { "推理 \($0.formatted()) tokens" },
                generation.latency.map { "延遲 \($0.formatted()) ms" },
                generation.cacheDiscount.map { "Cache 折扣 \(OpenRouterMoney.usd($0))" },
                generation.isByok == true ? generation.upstreamInferenceCost.map { "BYOK 推理費 \(OpenRouterMoney.usd($0))" } : nil,
                generation.finishReason.map { "完成原因 \($0)" },
            ].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tokens(_ count: Int?) -> String {
        count.map { $0.formatted() } ?? "–"
    }
}
