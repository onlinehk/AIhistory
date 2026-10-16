import Foundation
import Observation

/// USD per 1M tokens.
struct ModelPrice: Codable, Hashable, Sendable {
    var input: Double
    var cacheRead: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var output: Double

    /// Anthropic: cache writes are 1.25× input (5-minute TTL) or 2× (1-hour TTL).
    static func anthropic(_ input: Double, _ output: Double, cacheRead: Double) -> ModelPrice {
        ModelPrice(input: input, cacheRead: cacheRead, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2, output: output)
    }

    /// OpenAI doesn't charge extra for cache writes.
    static func openAI(_ input: Double, _ output: Double, cached: Double) -> ModelPrice {
        ModelPrice(input: input, cacheRead: cached, cacheWrite5m: input, cacheWrite1h: input, output: output)
    }

    func cost(_ u: TokenUsage) -> Double {
        (Double(u.input) * input
            + Double(u.cacheRead) * cacheRead
            + Double(u.cacheWrite5m) * cacheWrite5m
            + Double(u.cacheWrite1h) * cacheWrite1h
            + Double(u.output) * output) / 1_000_000
    }

    func scaled(_ factor: Double) -> ModelPrice {
        ModelPrice(input: input * factor, cacheRead: cacheRead * factor, cacheWrite5m: cacheWrite5m * factor,
                   cacheWrite1h: cacheWrite1h * factor, output: output * factor)
    }
}

/// Standard API list prices (short-context tier). Edited prices are stored on top of these.
@MainActor
@Observable
final class PriceBook {
    static let shared = PriceBook()

    /// Anthropic and OpenAI pricing pages as of 2026-10.
    static let defaults: [String: ModelPrice] = [
        "claude-fable-5-1": .anthropic(10, 50, cacheRead: 0.25),
        "claude-mythos-5-1": .anthropic(10, 50, cacheRead: 0.25),
        "claude-fable-5": .anthropic(10, 50, cacheRead: 1),
        "claude-mythos-5": .anthropic(10, 50, cacheRead: 1),
        "claude-opus-5-5": .anthropic(4, 20, cacheRead: 0.20),
        "claude-opus-5": .anthropic(5, 25, cacheRead: 0.50),
        "claude-opus-4-8": .anthropic(5, 25, cacheRead: 0.50),
        "claude-opus-4-7": .anthropic(5, 25, cacheRead: 0.50),
        "claude-opus-4-6": .anthropic(5, 25, cacheRead: 0.50),
        "claude-sonnet-5-5": .anthropic(2, 10, cacheRead: 0.20),
        "claude-sonnet-5": .anthropic(2, 10, cacheRead: 0.20),
        "claude-sonnet-4-6": .anthropic(3, 15, cacheRead: 0.30),
        "claude-sonnet-4-5": .anthropic(3, 15, cacheRead: 0.30),
        "claude-haiku-5-5": .anthropic(0.10, 0.50, cacheRead: 0.01),
        "claude-haiku-4-5": .anthropic(1, 5, cacheRead: 0.10),

        "gpt-6.1-sol": .openAI(2, 10, cached: 0.10),
        "gpt-6-astra": .openAI(10, 50, cached: 1),
        "gpt-6-sol": .openAI(2, 10, cached: 0.20),
        "gpt-6-luna": .openAI(0.10, 0.50, cached: 0.01),
        "gpt-5.6-sol": .openAI(4, 20, cached: 0.40),
        "gpt-5.6-terra": .openAI(2, 12, cached: 0.20),
        "gpt-5.6-luna": .openAI(0.20, 1.20, cached: 0.02),
        "gpt-5.5": .openAI(5, 30, cached: 0.50),
        "gpt-5.4": .openAI(2.50, 15, cached: 0.25),
        "gpt-5.4-mini": .openAI(0.75, 4.50, cached: 0.075),
        "gpt-5.3-codex": .openAI(1.75, 14, cached: 0.175),
        "gpt-5.2": .openAI(1.75, 14, cached: 0.175),
        "gpt-5.1": .openAI(1.25, 10, cached: 0.125),
        "gpt-5": .openAI(1.25, 10, cached: 0.125),
        "gpt-5-mini": .openAI(0.25, 2, cached: 0.025),
        "gpt-5-nano": .openAI(0.05, 0.40, cached: 0.005),
    ]

    private static let storageKey = "priceOverrides"

    private(set) var overrides: [String: ModelPrice] = [:]
    /// Models that appear in the history, so the price editor can list unpriced ones.
    var seenModels: Set<String> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: ModelPrice].self, from: data) {
            overrides = saved
        }
    }

    func setOverride(_ price: ModelPrice?, for model: String) {
        overrides[model] = price
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// "claude-haiku-4-5-20251001" -> "claude-haiku-4-5"; "claude-opus-5-5 (fast)" -> base model.
    nonisolated static func baseModel(_ model: String) -> (name: String, fast: Bool) {
        var name = model.lowercased()
        let fast = name.hasSuffix(" (fast)")
        if fast { name = String(name.dropLast(7)) }
        name = name.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return (name, fast)
    }

    /// Exact match first, then the longest known prefix ("gpt-5.5-codex" -> "gpt-5.5").
    func price(for model: String) -> ModelPrice? {
        let (name, fast) = Self.baseModel(model)
        if let p = overrides[model] ?? overrides[name] { return p }
        var candidate = name
        while !candidate.isEmpty {
            if let p = Self.defaults[candidate] { return fast ? p.scaled(2) : p }
            guard let cut = candidate.lastIndex(where: { $0 == "-" }) else { break }
            candidate = String(candidate[..<cut])
        }
        return nil
    }

    func isCustom(_ model: String) -> Bool { overrides[model] != nil }

    /// nil when the model has no price.
    func cost(_ usage: TokenUsage, model: String) -> Double? {
        price(for: model)?.cost(usage)
    }

    func cost(of session: SessionSummary) -> Double {
        session.usageByModel.reduce(0) { $0 + (cost($1.value, model: $1.key) ?? 0) }
    }

    func unpricedModels(in session: SessionSummary) -> [String] {
        session.usageByModel.keys.filter { price(for: $0) == nil }.sorted()
    }

    /// Every model either listed by default or seen in the history.
    var allModels: [String] {
        Set(Self.defaults.keys).union(seenModels.map { Self.baseModel($0).name }).sorted()
    }
}
