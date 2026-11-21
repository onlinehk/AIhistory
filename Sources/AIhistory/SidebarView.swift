import SwiftUI

struct SidebarView: View {
    let store: HistoryStore
    @Binding var filter: SourceFilter?
    /// Agents whose group is collapsed; empty by default so both start expanded.
    @State private var collapsed = Set<Agent>()
    @Environment(\.openWindow) private var openWindow
    private var allSources: Bool { (filter ?? .all) == .all }

    /// Always show each agent's main clients; show the rest only when they have sessions.
    private func sources(for agent: Agent) -> [SessionSource] {
        let main: [SessionSource]
        switch agent {
        case .claude: main = [.cli, .vscode, .desktop]
        case .codex: main = [.codexCLI, .codexVSCode, .codexApp]
        case .antigravity: return []
        }
        return SessionSource.allCases.filter { s in
            s.agent == agent && (main.contains(s) || store.count(for: .source(s)) > 0)
        }
    }

    var body: some View {
        List(selection: $filter) {
            Section {
                row(title: "所有來源", symbol: "tray.full", color: .secondary, count: store.count(for: .all))
                    .tag(SourceFilter.all)
            }

            agentSection(.claude)
            agentSection(.codex)
            agentSection(.antigravity)

            Section("統計") {
                let prices = PriceBook.shared
                ForEach(Agent.allCases) { agent in
                    let list = store.sessions.filter { $0.agent == agent }
                    let tokens = list.reduce(0) { $0 + $1.totalUsage.total }
                    let cost = list.reduce(0.0) { $0 + prices.cost(of: $1) }
                    let hasUnpricedModel = list.contains { prices.unpricedModels(in: $0).contains { $0 != "codex-auto-review" } }
                    VStack(alignment: .leading, spacing: 2) {
                        Label(agent.label, systemImage: agent.symbol)
                        Text("\(Fmt.usd(cost)) · \(Fmt.tokens(tokens))")
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        if agent == .codex && store.codexNeedsZstd {
                            Text("壓縮記錄未讀取，需要 zstd").font(.caption2).foregroundStyle(.orange)
                        }
                        if agent != .claude && hasUnpricedModel {
                            Text("部分用量未定價").font(.caption2).foregroundStyle(.orange)
                        }
                        if agent == .antigravity {
                            let withoutUsage = list.filter { $0.usage.isEmpty }.count
                            if withoutUsage > 0 {
                                Text("\(withoutUsage) 個對話未有用量記錄").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                openRouterRow
                Text("API 牌價估算，⇧⌘S 睇詳細").font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
    }

    private func agentSection(_ agent: Agent) -> some View {
        let expanded = !collapsed.contains(agent)
        let count = store.count(for: .agent(agent))
        return Section {
            if expanded {
                row(title: "全部", symbol: agent.symbol, color: agent.color, count: count)
                    .tag(SourceFilter.agent(agent))
                ForEach(sources(for: agent)) { s in
                    row(title: s.label, symbol: s.symbol, color: s.color, count: store.count(for: .source(s)))
                        .tag(SourceFilter.source(s))
                }
            }
        } header: {
            Button {
                if expanded { collapsed.insert(agent) } else { collapsed.remove(agent) }
            } label: {
                HStack {
                    Text(agent.label)
                    Spacer()
                    if !expanded { Text("\(count)").monospacedDigit() }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收合 \(agent.label)" : "展開 \(agent.label)")
        }
    }

    @ViewBuilder private var openRouterRow: some View {
        let or = OpenRouterStore.shared
        Button {
            openWindow(id: OpenRouterDetailView.windowID)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("OpenRouter", systemImage: "network")
                    Spacer()
                    Image(systemName: "arrow.up.right.square").font(.caption)
                }
                if allSources {
                    if let credits = or.credits.value {
                        Text("帳戶累計 \(Fmt.usd(credits.totalUsage))").monospacedDigit().foregroundStyle(.primary)
                    } else if let activity = or.activity.value {
                        Text("30 日扣費 \(Fmt.usd(activity.spend(days: 30)))").monospacedDigit().foregroundStyle(.primary)
                    } else if or.activity.isLoading || or.credits.isLoading {
                        Text("讀取整體用量…").foregroundStyle(.tertiary)
                    } else if or.hasKey(.management) {
                        Text("整體用量未能讀取").foregroundStyle(.secondary)
                    } else {
                        Text("設定 Management key 睇整體用量").foregroundStyle(.tertiary)
                    }
                    if let today = or.activity.value?.todaySpend {
                        Text("今日 UTC \(Fmt.usd(today))").font(.caption).monospacedDigit()
                    }
                } else if let info = or.keyInfo.value, info.isManagementKey != true {
                    Text("\(OpenRouterMoney.amount(info.usage)) · 今日 \(OpenRouterMoney.amount(info.usageDaily))")
                        .monospacedDigit().foregroundStyle(.primary)
                } else if let credits = or.credits.value {
                    Text("餘額 \(OpenRouterMoney.usd(credits.remaining))")
                        .monospacedDigit().foregroundStyle(.primary)
                } else if or.keyInfo.isLoading {
                    Text("讀取緊…").foregroundStyle(.tertiary)
                } else {
                    Text("用量明細與計費").foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("開啟 OpenRouter 統計與計費")
        .onChange(of: allSources, initial: true) { _, allSources in
            if allSources { or.refreshManagement(ifStale: true) } else { or.refreshKey(ifStale: true) }
        }
    }

    private func row(title: String, symbol: String, color: Color, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
}
