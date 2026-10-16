import SwiftUI

struct SidebarView: View {
    let store: HistoryStore
    @Binding var filter: SourceFilter?

    /// Always show each agent's main clients; show the rest only when they have sessions.
    private func sources(for agent: Agent) -> [SessionSource] {
        let main: [SessionSource] = agent == .claude ? [.cli, .vscode, .desktop] : [.codexCLI, .codexVSCode, .codexApp]
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

            ForEach(Agent.allCases) { agent in
                Section(agent.label) {
                    row(title: "全部", symbol: agent.symbol, color: agent.color,
                        count: store.count(for: .agent(agent)))
                        .tag(SourceFilter.agent(agent))
                    ForEach(sources(for: agent)) { s in
                        row(title: s.label, symbol: s.symbol, color: s.color, count: store.count(for: .source(s)))
                            .tag(SourceFilter.source(s))
                    }
                }
            }

            Section("統計") {
                let prices = PriceBook.shared
                ForEach(Agent.allCases) { agent in
                    let list = store.sessions.filter { $0.agent == agent }
                    let tokens = list.reduce(0) { $0 + $1.totalUsage.total }
                    let cost = list.reduce(0.0) { $0 + prices.cost(of: $1) }
                    VStack(alignment: .leading, spacing: 2) {
                        Label(agent.label, systemImage: agent.symbol)
                        Text("\(Fmt.usd(cost)) · \(Fmt.tokens(tokens))")
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }
                Text("API 牌價估算，⇧⌘S 睇詳細").font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
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
