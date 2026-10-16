import Foundation

/// Reads Codex rollouts: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (and `archived_sessions/`).
enum CodexParser {
    /// `~/.codex`, or `$CODEX_HOME` when set.
    static var root: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func sessionFiles() -> [URL] {
        var result: [URL] = []
        for sub in ["sessions", "archived_sessions"] {
            let dir = root.appendingPathComponent(sub)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                result.append(url)
            }
        }
        return result
    }

    /// Thread names from `session_index.jsonl` (later lines win).
    static func threadNames() -> [String: String] {
        var names: [String: String] = [:]
        HistoryParser.forEachRecord(in: root.appendingPathComponent("session_index.jsonl")) { rec in
            if let id = rec["id"] as? String, let name = rec["thread_name"] as? String, !name.isEmpty {
                names[id] = name
            }
        }
        return names
    }

    private static func isSubagent(_ meta: [String: Any]) -> Bool {
        if meta["parent_thread_id"] is String { return true }
        if let src = meta["source"] as? [String: Any], src["subagent"] != nil { return true }
        return false
    }

    // MARK: - User text

    /// Clients prepend context: "# Context from my IDE setup: …" (VS Code) or
    /// "# Files mentioned by the user: ## name: path …" (App), then "## My request for Codex: <text>".
    static func cleanUserText(_ raw: String) -> (text: String, context: [String], files: [(name: String, path: String)]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isIDE = trimmed.hasPrefix("# Context from my IDE setup")
        let isFiles = trimmed.hasPrefix("# Files mentioned by the user")
        guard isIDE || isFiles,
              let r = trimmed.range(of: "## My request for Codex:") ?? trimmed.range(of: "## My request:")
        else { return (trimmed, [], []) }

        var context: [String] = []
        var files: [(name: String, path: String)] = []
        for line in trimmed[..<r.lowerBound].split(separator: "\n") where line.hasPrefix("## ") {
            let entry = line.dropFirst(3)
            if isIDE {
                if entry.hasPrefix("Active file: ") {
                    let path = String(entry.dropFirst("Active file: ".count))
                    context.append("開啟: \((path as NSString).lastPathComponent)")
                }
            } else if let colon = entry.range(of: ": ") {
                files.append((String(entry[..<colon.lowerBound]), String(entry[colon.upperBound...])))
            }
        }
        return (String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), context, files)
    }

    private struct UserMessage {
        var text: String
        var context: [String]
        var files: [(name: String, path: String)]
        /// `data:` URLs embedded in the event.
        var imageURLs: [String] = []
        /// Pasted images Codex saved to a temp path.
        var localImages: [String] = []
    }

    private static func userMessage(_ item: [String: Any]) -> UserMessage {
        var parts: [String] = []
        var urls: [String] = []
        var locals: [String] = []
        for b in item["content"] as? [[String: Any]] ?? [] {
            switch b["type"] as? String {
            case "text": if let t = b["text"] as? String { parts.append(t) }
            case "image": if let u = b["image_url"] as? String { urls.append(u) }
            case "local_image": if let p = b["path"] as? String { locals.append(p) }
            default: break
            }
        }
        let cleaned = cleanUserText(parts.joined(separator: "\n"))
        return UserMessage(text: cleaned.text, context: cleaned.context, files: cleaned.files,
                           imageURLs: urls, localImages: locals)
    }

    // MARK: - Summary

    static func summarize(_ url: URL) -> SessionSummary? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast

        var meta: [String: Any]?
        var model: String?
        var firstPrompt: String?
        var prompts: [String] = []
        var promptCount = 0
        var start: Date?
        var end: Date?
        var usage: [UsageKey: TokenUsage] = [:]
        var lastTotal: [String: Int]?
        var searchBudget = 20_000

        HistoryParser.forEachRecord(in: url) { rec in
            let payload = rec["payload"] as? [String: Any] ?? [:]
            switch rec["type"] as? String {
            case "session_meta":
                if meta == nil { meta = payload }
                return
            case "turn_context":
                if let m = payload["model"] as? String { model = m }
                return
            case "event_msg":
                break
            default:
                return
            }
            if let d = HistoryParser.date(rec["timestamp"]) {
                if start == nil { start = d }
                end = d
            }
            switch payload["type"] as? String {
            case "thread_settings_applied":
                if let m = (payload["thread_settings"] as? [String: Any])?["model"] as? String { model = m }
            case "token_count":
                // Running totals; the change since the previous event belongs to the current model.
                guard let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else { return }
                let keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"]
                let current = Dictionary(uniqueKeysWithValues: keys.map { ($0, total[$0] as? Int ?? 0) })
                var delta = current.mapValues { $0 }
                if let lastTotal {
                    for k in keys { delta[k] = current[k]! - lastTotal[k]! }
                    if delta.values.contains(where: { $0 < 0 }) { delta = current }  // counter reset
                }
                lastTotal = current
                // OpenAI counts cached input inside input_tokens, and reasoning inside output_tokens.
                var u = TokenUsage()
                u.cacheRead = delta["cached_input_tokens"]!
                u.cacheWrite5m = delta["cache_write_input_tokens"]!
                u.input = max(0, delta["input_tokens"]! - u.cacheRead - u.cacheWrite5m)
                u.output = delta["output_tokens"]!
                u.reasoning = delta["reasoning_output_tokens"]!
                guard !u.isEmpty else { return }
                let day = HistoryParser.date(rec["timestamp"]).map(UsageKey.day(for:)) ?? "unknown"
                usage[UsageKey(day: day, model: model ?? "unknown"), default: TokenUsage()] += u
            case "item_completed":
                guard let item = payload["item"] as? [String: Any], (item["type"] as? String) == "UserMessage" else { return }
                let msg = userMessage(item)
                guard !msg.text.isEmpty else { return }
                promptCount += 1
                if firstPrompt == nil { firstPrompt = msg.text }
                if searchBudget > 0 {
                    let piece = String(msg.text.prefix(searchBudget))
                    prompts.append(piece)
                    searchBudget -= piece.count
                }
            default:
                break
            }
        }

        guard let meta else { return nil }
        let subagent = isSubagent(meta)
        guard subagent || promptCount > 0 else { return nil }

        let id = meta["id"] as? String ?? url.deletingPathExtension().lastPathComponent
        let project = meta["cwd"] as? String ?? ""
        let first = firstPrompt ?? ""
        let git = meta["git"] as? [String: Any]
        let originator = meta["originator"] as? String

        return SessionSummary(
            sessionId: id,
            fileURL: url,
            projectPath: project,
            title: fallbackTitle(first),
            firstPrompt: first,
            startDate: start ?? HistoryParser.date(meta["timestamp"]),
            endDate: end,
            promptCount: promptCount,
            source: SessionSource(codexOriginator: originator),
            rawEntrypoint: originator,
            gitBranch: git?["branch"] as? String,
            version: meta["cli_version"] as? String,
            model: model,
            usage: usage,
            isSubagent: subagent,
            parentSessionId: subagent ? (meta["parent_thread_id"] as? String ?? meta["session_id"] as? String) : nil,
            searchText: ([project] + prompts).joined(separator: "\n").lowercased(),
            fileSize: size,
            modified: modified
        )
    }

    static func fallbackTitle(_ firstPrompt: String) -> String {
        firstPrompt.isEmpty ? "(無標題)" : String(firstPrompt.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Transcript

    static func transcript(_ url: URL) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var toolIndex: [String: Int] = [:]
        var counter = 0
        func nextId() -> String { counter += 1; return "c\(counter)" }
        var attachmentCount = 0
        func nextName(_ prefix: String) -> (id: String, base: String) {
            attachmentCount += 1
            return ("a\(attachmentCount)", String(format: "%@-%02d", prefix, attachmentCount))
        }
        /// Pasted-image temp path -> data URL, from the model-facing copy of the user message
        /// (`<image name=[Image #1] path="…">` followed by an `input_image`).
        var pastedImages: [String: String] = [:]

        HistoryParser.forEachRecord(in: url) { rec in
            let payload = rec["payload"] as? [String: Any] ?? [:]
            let ts = HistoryParser.date(rec["timestamp"])
            let ptype = payload["type"] as? String

            switch rec["type"] as? String {
            case "event_msg":
                if ptype == "item_completed",
                   let item = payload["item"] as? [String: Any], (item["type"] as? String) == "UserMessage" {
                    let msg = userMessage(item)
                    var attachments: [Attachment] = []
                    var missing = 0
                    for url in msg.imageURLs {
                        let n = nextName("image")
                        if let a = Attachment.fromDataURL(url, id: n.id, baseName: n.base) { attachments.append(a) } else { missing += 1 }
                    }
                    for path in msg.localImages {
                        let n = nextName("image")
                        if FileManager.default.fileExists(atPath: path) {
                            attachments.append(Attachment(id: n.id, name: (path as NSString).lastPathComponent, source: .file(path: path)))
                        } else if let url = pastedImages[path], let a = Attachment.fromDataURL(url, id: n.id, baseName: n.base) {
                            attachments.append(a)
                        } else {
                            missing += 1
                        }
                    }
                    // Mentioned files are only referenced by path; pasted images are listed here too.
                    let imagePaths = Set(msg.localImages)
                    for file in msg.files where !imagePaths.contains(file.path) {
                        attachments.append(Attachment(id: nextName("file").id, name: file.name, source: .file(path: file.path)))
                    }
                    pastedImages.removeAll()
                    guard !msg.text.isEmpty || !attachments.isEmpty || missing > 0 else { return }
                    var u = TranscriptItem(id: nextId(), kind: .user, text: msg.text, date: ts)
                    u.context = msg.context
                    u.attachments = attachments
                    u.imageCount = missing
                    items.append(u)
                } else if ptype == "turn_aborted" {
                    items.append(TranscriptItem(id: nextId(), kind: .system, text: "⏹ 已中斷", date: ts))
                }

            case "response_item":
                switch ptype {
                case "message":
                    // User/developer messages here include injected context; the UserMessage events above are cleaner.
                    // Only borrow the embedded copies of pasted images from them.
                    if (payload["role"] as? String) == "user" {
                        var pendingPath: String?
                        for b in payload["content"] as? [[String: Any]] ?? [] {
                            if let t = b["text"] as? String, t.hasPrefix("<image name="),
                               let r = t.range(of: #"path="[^"]+""#, options: .regularExpression) {
                                pendingPath = String(t[r].dropFirst(6).dropLast())
                            } else if (b["type"] as? String) == "input_image", let path = pendingPath,
                                      let url = b["image_url"] as? String {
                                pastedImages[path] = url
                                pendingPath = nil
                            }
                        }
                        return
                    }
                    guard (payload["role"] as? String) == "assistant" else { return }
                    let text = (payload["content"] as? [[String: Any]] ?? [])
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        items.append(TranscriptItem(id: nextId(), kind: .assistant, text: text, date: ts))
                    }
                case "reasoning":
                    let text = (payload["summary"] as? [[String: Any]] ?? [])
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        items.append(TranscriptItem(id: nextId(), kind: .thinking, text: text, date: ts))
                    }
                case "function_call", "custom_tool_call", "local_shell_call", "web_search_call":
                    let tool = toolCall(payload, type: ptype!)
                    var t = TranscriptItem(id: nextId(), kind: .tool, text: tool.summary, date: ts)
                    t.title = tool.name
                    t.toolInput = tool.input
                    if let callId = payload["call_id"] as? String { toolIndex[callId] = items.count }
                    items.append(t)
                case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                    guard let callId = payload["call_id"] as? String, let idx = toolIndex[callId] else { return }
                    items[idx].toolResult = outputText(payload["output"])
                    for b in payload["output"] as? [[String: Any]] ?? [] {
                        guard (b["type"] as? String) == "input_image", let url = b["image_url"] as? String else { continue }
                        let n = nextName("tool")
                        if let a = Attachment.fromDataURL(url, id: n.id, baseName: n.base) { items[idx].attachments.append(a) }
                    }
                case "compaction":
                    items.append(TranscriptItem(id: nextId(), kind: .system, text: "── 對話已壓縮 ──", date: ts))
                default:
                    break
                }

            default:
                break
            }
        }
        return items
    }

    private static func toolCall(_ p: [String: Any], type: String) -> (name: String, summary: String, input: String) {
        switch type {
        case "web_search_call":
            let action = p["action"] as? [String: Any] ?? [:]
            let query = action["query"] as? String ?? (action["queries"] as? [String])?.joined(separator: " | ") ?? ""
            return ("web_search", query, prettyJSON(action))
        case "local_shell_call":
            let action = p["action"] as? [String: Any] ?? [:]
            let cmd = (action["command"] as? [String])?.joined(separator: " ") ?? ""
            return ("shell", cmd, prettyJSON(action))
        case "custom_tool_call":
            let name = p["name"] as? String ?? "tool"
            let input = p["input"] as? String ?? ""
            return (name, customSummary(input), input)
        default:
            let name = p["name"] as? String ?? "tool"
            let args = p["arguments"] as? String ?? ""
            if let data = args.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (prettyName(name), argsSummary(obj), prettyJSON(obj))
            }
            return (prettyName(name), String(args.prefix(160)), args)
        }
    }

    /// `exec` tool input is JS like `tools.exec_command({cmd:"ls -la", ...})`; pull out the command.
    private static func customSummary(_ input: String) -> String {
        if let r = input.range(of: #"cmd:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
            var cmd = String(input[r])
            cmd = cmd.replacingOccurrences(of: #"^cmd:\s*""#, with: "", options: .regularExpression)
            cmd.removeLast()
            return String(cmd.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ").prefix(160))
        }
        let firstLine = input.split(separator: "\n").first.map(String.init) ?? ""
        return String(firstLine.prefix(160))
    }

    private static func argsSummary(_ obj: [String: Any]) -> String {
        if let cmd = obj["command"] as? [String] { return String(cmd.joined(separator: " ").prefix(160)) }
        for k in ["cmd", "command", "path", "file_path", "query", "url", "pattern"] {
            if let v = obj[k] as? String, !v.isEmpty { return String(v.replacingOccurrences(of: "\n", with: " ").prefix(160)) }
        }
        return ""
    }

    private static func prettyName(_ name: String) -> String {
        // mcp__server__tool -> server · tool
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2 { return "\(parts[0]) · \(parts[1...].joined(separator: "__"))" }
        }
        return name
    }

    private static func outputText(_ output: Any?) -> String {
        var text: String
        if let s = output as? String {
            text = s
        } else if let blocks = output as? [[String: Any]] {
            text = blocks.compactMap { b -> String? in
                if let t = b["text"] as? String { return t }
                if (b["type"] as? String)?.contains("image") == true { return "[圖片]" }
                return nil
            }.joined(separator: "\n")
        } else if let obj = output as? [String: Any] {
            text = (obj["output"] as? String) ?? prettyJSON(obj)
        } else {
            text = ""
        }
        if text.count > 20_000 { text = String(text.prefix(20_000)) + "\n… (已截斷)" }
        return text
    }

    private static func prettyJSON(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8)
        else { return "\(obj)" }
        return s.count > 20_000 ? String(s.prefix(20_000)) + "\n… (已截斷)" : s
    }
}
