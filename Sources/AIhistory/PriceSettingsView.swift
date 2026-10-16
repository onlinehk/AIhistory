import SwiftUI

/// Settings → 價錢表: per-model USD per 1M tokens. Edits are stored on top of the built-in list prices.
struct PriceSettingsView: View {
    private let prices = PriceBook.shared
    @State private var filter = ""
    @State private var onlyUsed = true

    private var models: [String] {
        let used = Set(prices.seenModels.map { PriceBook.baseModel($0).name })
        return prices.allModels.filter { m in
            (!onlyUsed || used.contains(m)) && (filter.isEmpty || m.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("搵模型", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Toggle("只顯示用過嘅模型", isOn: $onlyUsed)
                Spacer()
            }
            Text("單位：每 1M tokens 美元。Claude 嘅 cache 寫入：5 分鐘 = 輸入 × 1.25、1 小時 = 輸入 × 2；OpenAI 唔另外收 cache 寫入。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("模型")
                        Text("輸入")
                        Text("Cache 讀")
                        Text("寫 5 分鐘")
                        Text("寫 1 小時")
                        Text("輸出")
                        Text("")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(models, id: \.self) { model in
                        PriceRow(model: model, prices: prices)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }
}

private struct PriceRow: View {
    let model: String
    let prices: PriceBook

    var body: some View {
        let current = prices.price(for: model)
        GridRow {
            HStack(spacing: 4) {
                Text(model).lineLimit(1)
                if current == nil {
                    Text("未定價").font(.caption).foregroundStyle(.orange)
                } else if prices.isCustom(model) {
                    Text("自訂").font(.caption).foregroundStyle(.blue)
                }
            }
            .frame(width: 210, alignment: .leading)
            field(\.input, current)
            field(\.cacheRead, current)
            field(\.cacheWrite5m, current)
            field(\.cacheWrite1h, current)
            field(\.output, current)
            Button {
                prices.setOverride(nil, for: model)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("還原預設價錢")
            .disabled(!prices.isCustom(model))
        }
    }

    private func field(_ key: WritableKeyPath<ModelPrice, Double>, _ current: ModelPrice?) -> some View {
        TextField("–", value: Binding(
            get: { current?[keyPath: key] },
            set: { newValue in
                var p = prices.price(for: model) ?? ModelPrice(input: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, output: 0)
                p[keyPath: key] = newValue ?? 0
                prices.setOverride(p, for: model)
            }
        ), format: .number.precision(.fractionLength(0...4)))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 80)
    }
}
