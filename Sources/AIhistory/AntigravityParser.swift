import Foundation
import SQLite3

/// The app and IDE can store the same conversation under both roots after a migration.
enum AntigravityParser {
    private static var roots: [URL] {
        let gemini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        return ["antigravity", "antigravity-ide", "antigravity-cli"].map { gemini.appendingPathComponent($0) }
    }

    static func summaries() -> [SessionSummary] {
        summaries(in: roots)
    }

    static func summaries(in roots: [URL]) -> [SessionSummary] {
        var files: [String: [URL]] = [:]
        var index: [String: ConversationInfo] = [:]
        let fm = FileManager.default
        for root in roots {
            let directory = root.appendingPathComponent("conversations")
            let candidates = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            for url in candidates where ["db", "pb"].contains(url.pathExtension) {
                let id = url.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                files[id, default: []].append(url)
            }
            guard let db = Database(root.appendingPathComponent("conversation_summaries.db")) else { continue }
            db.rows("""
                SELECT conversation_id, title, preview, workspace_uris, last_modified_time,
                       parent_conversation_id FROM conversation_summaries
                """) { row in
                guard let id = row.text(0), index[id] == nil else { return }
                let workspaces = row.text(3).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
                index[id] = ConversationInfo(title: nonempty(row.text(1)), preview: nonempty(row.text(2)),
                                             project: workspaces?.compactMap(filePath).first,
                                             modified: indexDate(row.text(4)), parent: nonempty(row.text(5)),
                                             indexURL: db.url)
            }
        }

        var sessions: [String: SessionSummary] = [:]
        for (id, versions) in files {
            let info = index[id]
            // Prefer the first readable SQLite version, in root order. The App's copy stays current after migration.
            let dbVersions = versions.filter { $0.pathExtension == "db" }
            if let summary = dbVersions.lazy.compactMap({ summarizeDatabase($0, id: id, info: info) }).first {
                sessions[id] = summary
            } else if let url = versions.first, let info {
                sessions[id] = summarizeIndex(url, id: id, info: info)
            }
        }

        var nested = Set<String>()
        for child in Array(sessions.values) where child.isSubagent {
            var visited = Set([child.sessionId])
            var parent = child.parentSessionId
            while let id = parent, visited.insert(id).inserted, let candidate = sessions[id] {
                if !candidate.isSubagent {
                    for (key, usage) in child.usage {
                        sessions[id]?.usage[key, default: TokenUsage()] += usage
                    }
                    nested.insert(child.sessionId)
                    break
                }
                parent = candidate.parentSessionId
            }
        }
        return sessions.values.filter { !nested.contains($0.sessionId) }
    }

    private struct ConversationInfo {
        let title: String?
        let preview: String?
        let project: String?
        let modified: Date?
        let parent: String?
        let indexURL: URL
    }

    private static func summarizeDatabase(_ url: URL, id: String, info: ConversationInfo?) -> SessionSummary? {
        guard let db = Database(url), db.rows("BEGIN", { _ in }) else { return nil }
        defer { db.rows("ROLLBACK") { _ in } }
        var dates: [Int: Date] = [:]
        var prompts: [String] = []
        var promptCount = 0
        var start: Date?
        var end: Date?
        let readSteps = db.rows("""
            SELECT idx, step_type, metadata, CASE WHEN step_type = 14 THEN step_payload END
            FROM steps ORDER BY idx
            """) { row in
            let index = row.int(0)
            if let date = Proto(row.blob(2))?.message(1)?.timestamp {
                dates[index] = date
                if start == nil { start = date }
                end = max(end ?? date, date)
            }
            if row.int(1) == 14 {
                promptCount += 1
                if let payload = Proto(row.blob(3)), let text = userText(payload) { prompts.append(text) }
            }
        }
        guard readSteps else { return nil }

        var usage: [UsageKey: TokenUsage] = [:]
        var usedResponses = Set<String>()
        var lastModel: String?
        var parent = info?.parent
        let readUsage = db.rows("SELECT data FROM gen_metadata ORDER BY idx") { row in
            guard let generation = Proto(row.blob(0)), let modelRecord = generation.message(1) else { return }
            let properties = modelRecord.messages(20)
            if parent == nil {
                parent = properties.first { $0.text(1) == "parent_cascade_id" }?.text(2).flatMap(nonempty)
            }
            guard let counts = modelRecord.message(4) else { return }
            let response = nonempty(counts.text(11)) ?? nonempty(generation.text(4))
            if let response, !usedResponses.insert(response).inserted { return }
            var total = TokenUsage()
            total.input = counts.int(2)
            total.cacheWrite5m = counts.int(4)
            total.cacheRead = counts.int(5)
            total.reasoning = counts.int(9)
            // The reported output total includes reasoning. Older entries may only report the components.
            total.output = max(counts.int(3), total.reasoning + counts.int(10))
            guard !total.isEmpty else { return }
            let model = modelName(display: modelRecord.text(21), config: modelRecord.text(19),
                                  modelNumber: counts.int(1))
            lastModel = model
            let date = modelRecord.message(9)?.message(4)?.timestamp
                ?? generation.firstPackedInt(2).flatMap { dates[$0] }
            let day = date.map(UsageKey.day(for:)) ?? "unknown"
            let longContext = model.hasPrefix("gemini-3.1-pro") && total.allInput > 200_000
            usage[UsageKey(day: day, model: model, longContext: longContext), default: TokenUsage()] += total
        }
        let hasUsage = readUsage && !usage.isEmpty
        guard promptCount > 0 || info != nil || hasUsage else { return nil }
        var localProject: String?
        if info?.project == nil {
            db.rows("SELECT data FROM trajectory_metadata_blob WHERE id = 'main'") { row in
                if let meta = Proto(row.blob(0)) {
                    localProject = (meta.text(7) ?? meta.message(1)?.text(1)).flatMap(filePath)
                }
            }
        }
        let first = prompts.first ?? info?.preview ?? ""
        return summary(url, id: id, info: info, project: localProject, prompts: prompts, first: first,
                       promptCount: promptCount, start: start, end: end, model: lastModel,
                       usage: hasUsage ? usage : [:], parent: parent)
    }

    private static func summarizeIndex(_ url: URL, id: String, info: ConversationInfo) -> SessionSummary {
        let items = indexTranscript(id: id, in: info.indexURL, usersOnly: true)
        let prompts = items.map(\.text)
        return summary(url, id: id, info: info, project: nil, prompts: prompts, first: prompts.first ?? info.preview ?? "",
                       promptCount: prompts.count, start: nil, end: info.modified, model: nil, usage: [:], parent: info.parent)
    }

    private static func summary(_ url: URL, id: String, info: ConversationInfo?, project: String?, prompts: [String],
                                first: String, promptCount: Int, start: Date?, end: Date?, model: String?,
                                usage: [UsageKey: TokenUsage], parent: String?) -> SessionSummary {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let walModified = url.pathExtension == "db" ? (try? fm.attributesOfItem(atPath: url.path + "-wal")[.modificationDate] as? Date) : nil
        let modified = max((attrs?[.modificationDate] as? Date) ?? .distantPast, walModified ?? .distantPast)
        let project = info?.project ?? project ?? ""
        let searchablePrompts = prompts.isEmpty ? [first] : prompts
        return SessionSummary(sessionId: id, fileURL: url, projectPath: project,
                              title: info?.title ?? CodexParser.fallbackTitle(first),
                              firstPrompt: first, startDate: start, endDate: end ?? info?.modified,
                              promptCount: promptCount, source: .antigravityLocal, rawEntrypoint: nil,
                              gitBranch: nil, version: nil, model: model, usage: usage,
                              isSubagent: parent != nil && parent != id, parentSessionId: parent != id ? parent : nil,
                              searchText: ([project] + searchablePrompts).joined(separator: "\n").prefix(20_000).lowercased(),
                              fileSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                              modified: modified)
    }

    static func transcript(_ url: URL) -> [TranscriptItem] {
        let id = url.deletingPathExtension().lastPathComponent
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        for directory in [root] + roots.filter({ $0 != root }) {
            let log = directory.appendingPathComponent("brain/\(id)/.system_generated/logs/transcript_full.jsonl")
            if let items = exportedTranscript(log), !items.isEmpty { return items }
        }
        if url.pathExtension == "db", let db = Database(url) {
            var items: [TranscriptItem] = []
            db.rows("SELECT idx, step_type, metadata, step_payload FROM steps WHERE step_type IN (14, 15) ORDER BY idx") { row in
                guard let payload = Proto(row.blob(3)) else { return }
                let idx = row.int(0)
                let date = Proto(row.blob(2))?.message(1)?.timestamp
                if row.int(1) == 14, let text = userText(payload) {
                    items.append(TranscriptItem(id: "u\(idx)", kind: .user, text: text, date: date))
                } else if let response = payload.message(20) {
                    if let thought = nonempty(response.text(3)) {
                        items.append(TranscriptItem(id: "t\(idx)", kind: .thinking, text: thought, date: date))
                    }
                    if let text = nonempty(response.text(1)) ?? nonempty(response.text(8)) {
                        items.append(TranscriptItem(id: "a\(idx)", kind: .assistant, text: text, date: date))
                    }
                }
            }
            if !items.isEmpty { return items }
        }
        for directory in [root] + roots.filter({ $0 != root }) {
            let items = indexTranscript(id: id, in: directory.appendingPathComponent("conversation_summaries.db"))
            if !items.isEmpty { return items }
        }
        return []
    }

    private static func exportedTranscript(_ url: URL) -> [TranscriptItem]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var items: [TranscriptItem] = []
        HistoryParser.forEachRecord(in: url) { row in
            let kind = row["type"] as? String
            let date = HistoryParser.date(row["created_at"])
            let content = nonempty(row["content"] as? String)
            func append(_ text: String, as type: TranscriptItem.Kind) {
                items.append(TranscriptItem(id: "agy\(items.count)", kind: type, text: text, date: date))
            }
            switch kind {
            case "USER_INPUT":
                if let content { append(content, as: .user) }
            case "PLANNER_RESPONSE":
                if let thought = nonempty(row["thinking"] as? String) { append(thought, as: .thinking) }
                if let content { append(content, as: .assistant) }
            case "EPHEMERAL_MESSAGE", "SYSTEM_MESSAGE":
                break
            default:
                if let content {
                    var item = TranscriptItem(id: "agy\(items.count)", kind: .tool, text: "", date: date)
                    item.title = (kind ?? "工具").replacingOccurrences(of: "_", with: " ").lowercased()
                    item.toolResult = content
                    items.append(item)
                }
            }
        }
        return items
    }

    /// Older histories have a local search index with UTF-8 byte offsets and original step indices.
    private static func indexTranscript(id: String, in url: URL, usersOnly: Bool = false) -> [TranscriptItem] {
        guard let db = Database(url) else { return [] }
        var items: [(step: Int, item: TranscriptItem)] = []
        var seen = Set<String>()
        db.rows("""
            SELECT user_body, user_step_byte_offsets, agent_body, agent_step_byte_offsets
            FROM conversations_fts WHERE conversation_id = ? ORDER BY chunk_index
            """, parameter: id) { row in
            func append(body: Int32, offsets: Int32, kind: TranscriptItem.Kind, prefix: String) {
                guard let body = row.text(body), let rawOffsets = row.text(offsets),
                      let entries = try? JSONDecoder().decode([[Int]].self, from: Data(rawOffsets.utf8)) else { return }
                let bytes = Array(body.utf8)
                for (i, entry) in entries.enumerated() where entry.count == 2 {
                    let step = entry[0]
                    let first = entry[1]
                    let next = i + 1 < entries.count ? entries[i + 1].last ?? bytes.count : bytes.count
                    let key = prefix + String(step)
                    guard first >= 0, next >= first, next <= bytes.count,
                          let text = nonempty(String(bytes: bytes[first..<next], encoding: .utf8)),
                          seen.insert(key).inserted else { continue }
                    items.append((step, TranscriptItem(id: key, kind: kind, text: text, date: nil)))
                }
            }
            append(body: 0, offsets: 1, kind: .user, prefix: "u")
            if !usersOnly { append(body: 2, offsets: 3, kind: .assistant, prefix: "a") }
        }
        return items.sorted { ($0.step, $0.item.id) < ($1.step, $1.item.id) }.map(\.item)
    }

    private static func userText(_ payload: Proto) -> String? {
        guard let user = payload.message(19) else { return nil }
        return nonempty(user.message(3)?.text(1)) ?? nonempty(user.text(2))
    }

    private static func modelName(display: String?, config: String?, modelNumber: Int) -> String {
        if let display = nonempty(display) {
            let base = display.components(separatedBy: " (")[0].lowercased().replacingOccurrences(of: " ", with: "-")
            return base.hasPrefix("claude-") ? base.replacingOccurrences(of: ".", with: "-") : base
        }
        // These ids and aliases were paired with display names in local generation records.
        if [1020, 1132].contains(modelNumber) { return "gemini-3.5-flash" }
        if let config = nonempty(config) { return config }
        return modelNumber == 0 ? "unknown" : "antigravity-model-\(modelNumber)"
    }

    private static func filePath(_ value: String) -> String? {
        guard let url = URL(string: value), url.isFileURL else { return nil }
        return url.path
    }

    private static func indexDate(_ raw: String?) -> Date? {
        guard let raw, !raw.hasPrefix("0001-") else { return nil }
        return HistoryParser.date(raw.replacingOccurrences(of: " ", with: "T", range: raw.range(of: " ")))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

private final class Database {
    let url: URL
    private let handle: OpaquePointer

    init?(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.url = url
        var database: OpaquePointer?
        let walPath = url.path + "-wal"
        let walBytes = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber)?.intValue ?? 0
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        // SQLite needs access to its WAL index even for read-only connections. With no frames,
        // the on-disk database is complete and can also be opened in a read-only directory.
        let path = walBytes <= 32 ? url.absoluteString + "?immutable=1" : url.absoluteString
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        sqlite3_busy_timeout(database, 500)
        handle = database
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func rows(_ sql: String, parameter: String? = nil, _ read: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        if let parameter {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, parameter, -1, transient)
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            read(Row(statement: statement))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE
    }

    struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func blob(_ column: Int32) -> Data? {
            guard let ptr = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: ptr, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}

/// Minimal protobuf wire reader for the fields used by Antigravity's local storage.
private struct Proto {
    private enum Field { case number(UInt64), bytes(Data) }
    private let fields: [Int: [Field]]

    init?(_ data: Data?) {
        guard let data else { return nil }
        var fields: [Int: [Field]] = [:]
        var offset = data.startIndex
        while offset < data.endIndex {
            guard let tag = Self.varint(data, offset: &offset), tag >> 3 > 0, tag >> 3 < (1 << 29) else { return nil }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = Self.varint(data, offset: &offset) else { return nil }
                fields[number, default: []].append(.number(value))
            case 2:
                guard let length = Self.varint(data, offset: &offset), length <= data.endIndex - offset else { return nil }
                let end = offset + Int(length)
                fields[number, default: []].append(.bytes(data[offset..<end]))
                offset = end
            case 1, 5:
                let size = tag & 7 == 1 ? 8 : 4
                guard size <= data.endIndex - offset else { return nil }
                offset += size
            default: return nil
            }
        }
        self.fields = fields
    }

    private static func varint(_ data: Data, offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.endIndex else { return nil }
            let byte = data[offset]
            offset += 1
            if shift == 63 && byte > 1 { return nil }
            value |= UInt64(byte & 127) << shift
            if byte < 128 { return value }
        }
        return nil
    }

    func int(_ number: Int) -> Int {
        guard case let .number(value)? = fields[number]?.first else { return 0 }
        return Int(exactly: value) ?? 0
    }

    func firstPackedInt(_ number: Int) -> Int? {
        switch fields[number]?.first {
        case let .number(value)?: return Int(exactly: value)
        case let .bytes(data)?:
            var offset = data.startIndex
            return Self.varint(data, offset: &offset).flatMap(Int.init(exactly:))
        case nil: return nil
        }
    }

    private func bytes(_ number: Int) -> Data? {
        guard case let .bytes(data)? = fields[number]?.first else { return nil }
        return data
    }

    func text(_ number: Int) -> String? { bytes(number).flatMap { String(data: $0, encoding: .utf8) } }
    func message(_ number: Int) -> Proto? { Proto(bytes(number)) }

    func messages(_ number: Int) -> [Proto] {
        (fields[number] ?? []).compactMap { field in
            guard case let .bytes(data) = field else { return nil }
            return Proto(data)
        }
    }

    var timestamp: Date? {
        let seconds = int(1)
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(int(2)) / 1_000_000_000)
    }
}
