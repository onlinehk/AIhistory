import Foundation
import CryptoKit
import Observation
import Security

struct OpenRouterKeyInfo: Decodable, Sendable {
    let label: String?
    let limit: Double?
    let limitRemaining: Double?
    let limitReset: String?
    let usage: Double?
    let usageDaily: Double?
    let usageWeekly: Double?
    let usageMonthly: Double?
    let byokUsage: Double?
    let byokUsageDaily: Double?
    let byokUsageWeekly: Double?
    let byokUsageMonthly: Double?
    let isFreeTier: Bool?
    let isManagementKey: Bool?
}

struct OpenRouterCredits: Decodable, Sendable {
    let totalCredits: Double
    let totalUsage: Double

    var remaining: Double { totalCredits - totalUsage }
}

struct OpenRouterActivity: Decodable, Sendable {
    let date: String
    let model: String
    let providerName: String?
    let requests: Int
    let promptTokens: Int
    let completionTokens: Int
    let reasoningTokens: Int
    let cachedTokens: Int?
    let usage: Double
    let byokUsageInference: Double

    private enum CodingKeys: String, CodingKey {
        case date, model, providerName, requests, promptTokens, completionTokens, reasoningTokens, cachedTokens, usage, byokUsageInference
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let rawDate = try fields.decode(String.self, forKey: .date)
        guard let date = OpenRouterActivityPeriod.day(from: rawDate) else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: fields, debugDescription: "Invalid OpenRouter activity date")
        }
        self.init(date: date, model: try fields.decode(String.self, forKey: .model),
                  providerName: try fields.decodeIfPresent(String.self, forKey: .providerName),
                  requests: try fields.decode(Int.self, forKey: .requests),
                  promptTokens: try fields.decode(Int.self, forKey: .promptTokens),
                  completionTokens: try fields.decode(Int.self, forKey: .completionTokens),
                  reasoningTokens: try fields.decode(Int.self, forKey: .reasoningTokens),
                  cachedTokens: try fields.decodeIfPresent(Int.self, forKey: .cachedTokens),
                  usage: try fields.decode(Double.self, forKey: .usage),
                  byokUsageInference: try fields.decode(Double.self, forKey: .byokUsageInference))
    }

    fileprivate init(date: String, model: String, providerName: String?, requests: Int, promptTokens: Int,
                     completionTokens: Int, reasoningTokens: Int, cachedTokens: Int?, usage: Double, byokUsageInference: Double) {
        self.date = date
        self.model = model
        self.providerName = providerName
        self.requests = requests
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.cachedTokens = cachedTokens
        self.usage = usage
        self.byokUsageInference = byokUsageInference
    }
}

struct OpenRouterUsage: Sendable {
    var requests = 0
    var prompt = 0
    var completion = 0
    var reasoning = 0
    private var cached = 0
    private var cachePrompt = 0
    var cost = 0.0
    var byok = 0.0

    var cacheHitRate: Double? {
        guard cachePrompt > 0 else { return nil }
        return Double(cached) / Double(cachePrompt)
    }

    var hasPartialCache: Bool { cachePrompt > 0 && cachePrompt < prompt }

    mutating func add(_ row: OpenRouterActivity) {
        requests += row.requests
        prompt += row.promptTokens
        completion += row.completionTokens
        reasoning += row.reasoningTokens
        // Response-cache replays can report more cached tokens than prompt tokens.
        if let tokens = row.cachedTokens, tokens <= row.promptTokens {
            cached += tokens
            cachePrompt += row.promptTokens
        }
        cost += row.usage
        byok += row.byokUsageInference
    }
}

struct OpenRouterActivityPeriod {
    private static let dayFormat = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash)
    let days: [String]

    init(count: Int, now: Date, includesToday: Bool) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let today = utc.startOfDay(for: now)
        let firstOffset = includesToday ? 0 : 1
        days = (firstOffset..<(firstOffset + count)).reversed().compactMap {
            utc.date(byAdding: .day, value: -$0, to: today)?.formatted(Self.dayFormat)
        }
    }

    static func day(from raw: String) -> String? {
        if let instant = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
            return instant.formatted(dayFormat)
        }
        if let instant = try? Date.ISO8601FormatStyle().parse(raw) {
            return instant.formatted(dayFormat)
        }
        // Activity also returns UTC timestamps like "2026-11-13 00:00:00".
        let day = String(raw.prefix(10))
        guard raw.count == 10 || raw.dropFirst(10).first == " ",
              let date = try? dayFormat.parse(day), date.formatted(dayFormat) == day else { return nil }
        return day
    }

    func rows(from activity: [OpenRouterActivity]) -> [OpenRouterActivity] {
        guard let first = days.first, let last = days.last else { return [] }
        return activity.filter { $0.date >= first && $0.date <= last }
    }
}

struct OpenRouterActivitySnapshot: Sendable {
    let rows: [OpenRouterActivity]
    let requestedAt: Date
    let includesToday: Bool
    let notice: String?

    func period(days: Int) -> OpenRouterActivityPeriod {
        OpenRouterActivityPeriod(count: days, now: requestedAt, includesToday: includesToday)
    }

    func spend(days: Int) -> Double {
        period(days: days).rows(from: rows).reduce(0) { $0 + $1.usage }
    }

    var todaySpend: Double? { includesToday ? spend(days: 1) : nil }
}

private struct OpenRouterAnalyticsQuery: Encodable {
    struct TimeRange: Encodable { let start: String; let end: String }

    let dimensions = ["model", "provider"]
    let metrics = ["credits_usage", "byok_usage", "request_count", "tokens_prompt", "tokens_completion", "reasoning_tokens", "cached_tokens"]
    let granularity = "day"
    let limit = 10_000
    let timeRange: TimeRange
}

private struct OpenRouterAnalyticsResult: Decodable, Sendable {
    struct Metadata: Decodable, Sendable { let truncated: Bool }
    let data: [Row]
    let metadata: Metadata

    struct Row: Decodable, Sendable {
        let activity: OpenRouterActivity

        private enum CodingKeys: String, CodingKey {
            case dateDay, createdAtDay, model, provider, creditsUsage, byokUsage, requestCount
            case tokensPrompt, tokensCompletion, reasoningTokens, cachedTokens
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let rawDate = try fields.decodeIfPresent(String.self, forKey: .dateDay)
                ?? fields.decode(String.self, forKey: .createdAtDay)
            guard let day = OpenRouterActivityPeriod.day(from: rawDate) else {
                throw DecodingError.dataCorruptedError(forKey: .dateDay, in: fields, debugDescription: "Invalid OpenRouter analytics date")
            }
            activity = OpenRouterActivity(
                date: day, model: try fields.decodeIfPresent(String.self, forKey: .model) ?? "",
                providerName: try fields.decodeIfPresent(String.self, forKey: .provider),
                requests: try fields.metric(Int.self, forKey: .requestCount) ?? 0,
                promptTokens: try fields.metric(Int.self, forKey: .tokensPrompt) ?? 0,
                completionTokens: try fields.metric(Int.self, forKey: .tokensCompletion) ?? 0,
                reasoningTokens: try fields.metric(Int.self, forKey: .reasoningTokens) ?? 0,
                cachedTokens: try fields.metric(Int.self, forKey: .cachedTokens),
                usage: try fields.metric(Double.self, forKey: .creditsUsage) ?? 0,
                byokUsageInference: try fields.metric(Double.self, forKey: .byokUsage) ?? 0
            )
        }
    }
}

private extension KeyedDecodingContainer {
    func metric<Value: Decodable & LosslessStringConvertible>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        if try decodeNil(forKey: key) { return nil }
        if let value = try? decode(type, forKey: key) { return value }
        if let number = try? decode(String.self, forKey: key), let value = Value(number) { return value }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid OpenRouter metric")
    }
}

struct OpenRouterGeneration: Decodable, Sendable {
    let id: String
    let createdAt: String?
    let model: String?
    let providerName: String?
    let totalCost: Double?
    let usage: Double?
    let isByok: Bool?
    let upstreamInferenceCost: Double?
    let cacheDiscount: Double?
    let nativeTokensPrompt: Int?
    let nativeTokensCompletion: Int?
    let nativeTokensReasoning: Int?
    let nativeTokensCached: Int?
    let tokensPrompt: Int?
    let tokensCompletion: Int?
    let latency: Int?
    let finishReason: String?

    var cost: Double? { totalCost ?? usage }
}

struct OpenRouterAPI: Sendable {
    enum Endpoint: String {
        case key, credits, activity, generation
        case analytics = "analytics/query"
    }

    private struct Envelope<Value: Decodable>: Decodable { let data: Value }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static let live = OpenRouterAPI(session: URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil))
    let session: URLSession

    func get<Value: Decodable & Sendable>(_ endpoint: Endpoint, key: String, query: [URLQueryItem] = []) async throws -> Value {
        try await request(endpoint, key: key, query: query)
    }

    func activitySnapshot(key: String, now: Date = .now) async throws -> OpenRouterActivitySnapshot {
        let period = OpenRouterActivityPeriod(count: 30, now: now, includesToday: true)
        let query = OpenRouterAnalyticsQuery(timeRange: .init(start: period.days[0] + "T00:00:00Z", end: now.ISO8601Format()))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            let result: OpenRouterAnalyticsResult = try await request(.analytics, key: key, payload: encoder.encode(query))
            guard !result.metadata.truncated else { throw AnalyticsTruncated() }
            return OpenRouterActivitySnapshot(rows: result.data.map(\.activity), requestedAt: now, includesToday: true, notice: nil)
        } catch {
            try Task.checkCancellation()
            if let http = error as? HTTPError, http.status == 401 || http.status == 429 { throw error }
            let rows: [OpenRouterActivity] = try await get(.activity, key: key)
            let reason = error is DecodingError ? "OpenRouter Analytics 回傳格式未能讀取" : error.localizedDescription
            return OpenRouterActivitySnapshot(rows: rows, requestedAt: now, includesToday: false, notice: reason)
        }
    }

    private struct AnalyticsTruncated: LocalizedError {
        var errorDescription: String? { "OpenRouter Analytics 明細超出回傳上限" }
    }

    private func request<Value: Decodable & Sendable>(_ endpoint: Endpoint, key: String, query: [URLQueryItem] = [],
                                                        payload: Data? = nil) async throws -> Value {
        var address = URLComponents()
        address.scheme = "https"
        address.host = "openrouter.ai"
        address.path = "/api/v1/\(endpoint.rawValue)"
        if !query.isEmpty { address.queryItems = query }
        guard let url = address.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw HTTPError(status: http.statusCode, endpoint: endpoint) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Envelope<Value>.self, from: data).data
    }

    struct HTTPError: LocalizedError {
        let status: Int
        let endpoint: Endpoint

        var errorDescription: String? {
            switch (status, endpoint) {
            case (401, _): return "Key 無效、已過期或者已被撤銷 (401)"
            case (403, .credits): return "查餘額需要帳戶層級、有權讀取 credits 嘅 Management key (403)"
            case (403, .activity): return "查用量需要有 Activity 讀取權限嘅 Management key (403)"
            case (403, .analytics): return "呢條 Management key 冇 Analytics 讀取權限 (403)"
            case (403, .generation): return "呢條 key 冇權限查閱呢個 generation (403)"
            case (404, .generation): return "搵唔到呢個 generation，請核對 ID 同 API key (404)"
            case (429, _): return "OpenRouter 請求過多，請稍後再試 (429)"
            default: return "OpenRouter 回應錯誤 (HTTP \(status))"
            }
        }
    }
}

enum OpenRouterCredential: String, CaseIterable {
    case api = "api-key"
    case management = "management-key"

    var label: String {
        switch self {
        case .api: "普通 API key"
        case .management: "Management key"
        }
    }
}

enum OpenRouterKeychain {
    private static func query(_ credential: OpenRouterCredential) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.aihistory.openrouter",
         kSecAttrAccount as String: credential.rawValue]
    }

    static func load(_ credential: OpenRouterCredential) -> String? {
        var q = query(credential)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, for credential: OpenRouterCredential) throws {
        let q = query(credential)
        let status: OSStatus
        if key.isEmpty {
            status = SecItemDelete(q as CFDictionary)
            if status == errSecItemNotFound { return }
        } else {
            let values = [kSecValueData as String: Data(key.utf8)]
            let added = SecItemAdd(q.merging(values) { _, new in new } as CFDictionary, nil)
            status = added == errSecDuplicateItem ? SecItemUpdate(q as CFDictionary, values as CFDictionary) : added
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "未能更新 macOS Keychain (\(status))" }
    }
}

struct OpenRouterReport<Value> {
    var value: Value?
    var isLoading = false
    var error: String?
    var updatedAt: Date?
}

struct SpendPoint: Identifiable {
    var id: Date { day }
    let day: Date
    let cost: Double
}

@MainActor
@Observable
final class OpenRouterStore {
    static let shared = OpenRouterStore()

    private(set) var keyInfo = OpenRouterReport<OpenRouterKeyInfo>()
    private(set) var activity = OpenRouterReport<OpenRouterActivitySnapshot>()
    private(set) var credits = OpenRouterReport<OpenRouterCredits>()
    private(set) var generation = OpenRouterReport<OpenRouterGeneration>()
    private(set) var snapshots: [String: Double] = [:]
    private var configured: Set<OpenRouterCredential> = []

    @ObservationIgnored private var keyTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var creditsTask: Task<Void, Never>?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotStorageKey: String?

    private init() {
        let standardKey = OpenRouterKeychain.load(.api)
        if let standardKey {
            configured.insert(.api)
            loadSnapshots(for: standardKey, migrate: true)
        }
        if OpenRouterKeychain.load(.management) != nil { configured.insert(.management) }
    }

    func hasKey(_ credential: OpenRouterCredential) -> Bool { configured.contains(credential) }

    func setKey(_ draft: String, for credential: OpenRouterCredential) throws {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        try OpenRouterKeychain.set(key, for: credential)
        if key.isEmpty { configured.remove(credential) } else { configured.insert(credential) }
        switch credential {
        case .api:
            keyTask?.cancel()
            keyInfo = OpenRouterReport()
            loadSnapshots(for: key)
            refreshKey()
        case .management:
            activityTask?.cancel()
            creditsTask?.cancel()
            activity = OpenRouterReport()
            credits = OpenRouterReport()
            refreshManagement()
        }
        generationTask?.cancel()
        generation = OpenRouterReport()
    }

    func refreshKey(ifStale: Bool = false) {
        guard let key = OpenRouterKeychain.load(.api) else { return }
        if let task = fetch(\.keyInfo, ifStale: ifStale, request: { try await OpenRouterAPI.live.get(.key, key: key) }, didLoad: { [weak self] info in
            if info.isManagementKey != true, let value = info.usage { self?.record(value) }
        }) {
            keyTask = task
        }
    }

    func refreshManagement(ifStale: Bool = false) {
        guard let key = OpenRouterKeychain.load(.management) else { return }
        if let task = fetch(\.activity, ifStale: ifStale, request: { try await OpenRouterAPI.live.activitySnapshot(key: key) }) {
            activityTask = task
        }
        if let task = fetch(\.credits, ifStale: ifStale, request: { try await OpenRouterAPI.live.get(.credits, key: key) }) {
            creditsTask = task
        }
    }

    func lookupGeneration(_ draft: String, with credential: OpenRouterCredential) {
        let id = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !generation.isLoading, let key = OpenRouterKeychain.load(credential) else { return }
        generation = OpenRouterReport()
        generationTask = fetch(\.generation, request: {
            try await OpenRouterAPI.live.get(.generation, key: key, query: [URLQueryItem(name: "id", value: id)])
        })
    }

    private func fetch<Value: Sendable>(_ report: ReferenceWritableKeyPath<OpenRouterStore, OpenRouterReport<Value>>,
                                        ifStale: Bool = false, request: @escaping () async throws -> Value,
                                        didLoad: ((Value) -> Void)? = nil) -> Task<Void, Never>? {
        guard !self[keyPath: report].isLoading else { return nil }
        if ifStale, let updated = self[keyPath: report].updatedAt, Date().timeIntervalSince(updated) < 60 { return nil }
        self[keyPath: report].isLoading = true
        self[keyPath: report].error = nil
        return Task { [weak self] in
            do {
                let value = try await request()
                guard !Task.isCancelled, let self else { return }
                self[keyPath: report] = OpenRouterReport(value: value, updatedAt: .now)
                didLoad?(value)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self[keyPath: report].isLoading = false
                self[keyPath: report].error = error is DecodingError ? "OpenRouter 回傳嘅資料格式未能讀取" : error.localizedDescription
            }
        }
    }

    // Attribute cumulative snapshots to the configured key, without storing the secret in preferences.
    private func loadSnapshots(for key: String, migrate: Bool = false) {
        snapshots = [:]
        snapshotStorageKey = nil
        guard !key.isEmpty else { return }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacy = "openRouterSnapshots"
        let storage = "\(legacy).\(digest)"
        snapshotStorageKey = storage
        let defaults = UserDefaults.standard
        if migrate, let old = defaults.data(forKey: legacy) {
            if defaults.object(forKey: storage) == nil { defaults.set(old, forKey: storage) }
            defaults.removeObject(forKey: legacy)
        }
        if let data = defaults.data(forKey: storage) {
            snapshots = (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
        }
    }

    private func record(_ cumulative: Double) {
        guard let snapshotStorageKey else { return }
        snapshots[UsageKey.day(for: .now)] = cumulative
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: snapshotStorageKey)
        }
    }

    func clearHistory() {
        snapshots = [:]
        if let snapshotStorageKey { UserDefaults.standard.removeObject(forKey: snapshotStorageKey) }
    }

    func dailySpend(since: String?) -> [SpendPoint] {
        let days = snapshots.keys.sorted()
        return zip(days, days.dropFirst()).compactMap { prev, cur in
            guard since.map({ cur >= $0 }) ?? true, let date = UsageKey.date(forDay: cur),
                  let current = snapshots[cur], let previous = snapshots[prev], current > previous else { return nil }
            return SpendPoint(day: date, cost: current - previous)
        }
    }
}
