import Foundation

enum HistoryParser {
    /// `~/.claude/projects`, or `$CLAUDE_CONFIG_DIR/projects` when set.
    static var projectsRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Top-level session files: `projects/<encoded-cwd>/<session-id>.jsonl`.
    static func sessionFiles() -> [URL] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for dir in projects {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            result.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
        }
        return result
    }

    // MARK: - JSONL

    static func forEachRecord(in url: URL, _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        var start = data.startIndex
        let end = data.endIndex
        while start < end {
            let lineEnd = data[start..<end].firstIndex(of: 0x0A) ?? end
            if lineEnd > start,
               let obj = try? JSONSerialization.jsonObject(with: data[start..<lineEnd]) as? [String: Any] {
                body(obj)
            }
            start = lineEnd + 1
        }
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }

    // MARK: - User text cleanup

    struct CleanedUserText {
        var text: String
        var context: [String]
        var imageCount: Int
        var isCommandOutput: Bool
    }

    /// Splits IDE/system tags out of a user message so only what the person typed remains.
    static func cleanUserContent(_ content: Any?) -> CleanedUserText {
        var raw = ""
        var images = 0
        if let s = content as? String {
            raw = s
        } else if let blocks = content as? [[String: Any]] {
            var parts: [String] = []
            for b in blocks {
                switch b["type"] as? String {
                case "text": if let t = b["text"] as? String { parts.append(t) }
                case "image": images += 1
                default: break
                }
            }
            raw = parts.joined(separator: "\n")
        }

        var context: [String] = []
        var text = raw

        // IDE context: keep a short chip, drop from body.
        for tag in ["ide_opened_file", "ide_selection", "ide_diagnostics"] {
            for inner in extractTags(tag, from: &text) {
                context.append(ideChip(tag: tag, inner: inner))
            }
        }
        _ = extractTags("system-reminder", from: &text)

        // Slash commands: <command-name>/foo</command-name><command-args>bar</command-args>
        var isCommandOutput = false
        let names = extractTags("command-name", from: &text)
        let args = extractTags("command-args", from: &text)
        _ = extractTags("command-message", from: &text)
        if let name = names.first {
            let a = args.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text = (a.isEmpty ? name : "\(name) \(a)") + text
        }
        for tag in ["local-command-stdout", "local-command-stderr", "bash-stdout", "bash-stderr"] {
            let out = extractTags(tag, from: &text)
            if !out.isEmpty {
                isCommandOutput = true
                text += out.joined(separator: "\n")
            }
        }
        let bash = extractTags("bash-input", from: &text)
        if let cmd = bash.first { text = "! " + cmd + text }

        // Image placeholders like "[Image: source: /tmp/...]"
        text = text.replacingOccurrences(
            of: #"\[Image(?: #\d+)?:[^\]]*\]"#, with: "", options: .regularExpression
        )

        return CleanedUserText(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            context: context,
            imageCount: images,
            isCommandOutput: isCommandOutput
        )
    }

    private static func ideChip(tag: String, inner: String) -> String {
        // "The user opened the file /path/to/file.php in the IDE. ..."
        if let range = inner.range(of: #"/[^\s]+"#, options: .regularExpression) {
            var path = String(inner[range])
            while let last = path.last, ".,:".contains(last) { path.removeLast() }
            let file = (path as NSString).lastPathComponent
            switch tag {
            case "ide_selection": return "選取: \(file)"
            case "ide_diagnostics": return "診斷: \(file)"
            default: return "開啟: \(file)"
            }
        }
        return tag == "ide_selection" ? "IDE 選取" : "IDE"
    }

    /// Removes every `<tag>…</tag>` from `text` and returns the inner contents.
    private static func extractTags(_ tag: String, from text: inout String) -> [String] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var found: [String] = []
        while let o = text.range(of: open) {
            guard let c = text.range(of: close, range: o.upperBound..<text.endIndex) else {
                text.removeSubrange(o)
                break
            }
            found.append(String(text[o.upperBound..<c.lowerBound]))
            text.removeSubrange(o.lowerBound..<c.upperBound)
        }
        return found
    }

    private static func isToolResultOnly(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]], !blocks.isEmpty else { return false }
        return blocks.allSatisfy { ($0["type"] as? String) == "tool_result" }
    }

    // MARK: - Summary

    static func summarize(_ url: URL) -> SessionSummary? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast

        var sessionId = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var entrypoint: String?
        var gitBranch: String?
        var version: String?
        var model: String?
        var customTitle: String?
        var aiTitle: String?
        var firstPrompt: String?
        var prompts: [String] = []
        var promptCount = 0
        var start: Date?
        var end: Date?
        var searchBudget = 20_000
        // Streamed replies repeat the same usage on every content-block record; keep one per message id.
        var replyUsage: [String: (key: UsageKey, usage: TokenUsage)] = [:]

        forEachRecord(in: url) { rec in
            let type = rec["type"] as? String
            switch type {
            case "custom-title":
                if let t = rec["customTitle"] as? String, !t.isEmpty { customTitle = t }
                return
            case "ai-title":
                if let t = rec["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
                return
            case "user", "assistant":
                break
            default:
                return
            }
            // Sub-agent replies are hidden from the transcript but still cost tokens.
            if type == "assistant", let message = rec["message"] as? [String: Any],
               let reply = claudeUsage(message, timestamp: rec["timestamp"]) {
                replyUsage[(message["id"] as? String) ?? (rec["uuid"] as? String ?? UUID().uuidString)] = reply
            }
            if (rec["isSidechain"] as? Bool) == true { return }

            if let d = date(rec["timestamp"]) {
                if start == nil { start = d }
                end = d
            }
            if cwd == nil, let c = rec["cwd"] as? String { cwd = c }
            if entrypoint == nil, let e = rec["entrypoint"] as? String { entrypoint = e }
            if let b = rec["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { gitBranch = b }
            if let v = rec["version"] as? String { version = v }
            if let s = rec["sessionId"] as? String { sessionId = s }

            let message = rec["message"] as? [String: Any]
            if type == "assistant" {
                if let m = message?["model"] as? String, m != "<synthetic>" { model = m }
                return
            }
            if (rec["isMeta"] as? Bool) == true || (rec["isCompactSummary"] as? Bool) == true { return }
            let content = message?["content"]
            if isToolResultOnly(content) { return }
            let cleaned = cleanUserContent(content)
            guard !cleaned.text.isEmpty, !cleaned.isCommandOutput else { return }
            if cleaned.text.hasPrefix("[Request interrupted") { return }
            promptCount += 1
            if firstPrompt == nil { firstPrompt = cleaned.text }
            if searchBudget > 0 {
                let piece = String(cleaned.text.prefix(searchBudget))
                prompts.append(piece)
                searchBudget -= piece.count
            }
        }

        // Skip files with no conversation at all (e.g. only metadata records).
        guard promptCount > 0 || customTitle != nil || aiTitle != nil else { return nil }

        let project = cwd ?? decodeProjectDir(url.deletingLastPathComponent().lastPathComponent)
        let first = firstPrompt ?? ""
        let title = customTitle ?? aiTitle ?? (first.isEmpty ? "(無標題)" : String(first.prefix(80)))
        let search = ([title, project] + prompts).joined(separator: "\n").lowercased()

        return SessionSummary(
            sessionId: sessionId,
            fileURL: url,
            projectPath: project,
            title: title.replacingOccurrences(of: "\n", with: " "),
            firstPrompt: first,
            startDate: start,
            endDate: end,
            promptCount: promptCount,
            source: SessionSource(entrypoint: entrypoint),
            rawEntrypoint: entrypoint,
            gitBranch: gitBranch,
            version: version,
            model: model,
            usage: replyUsage.values.reduce(into: [:]) { $0[$1.key, default: TokenUsage()] += $1.usage },
            searchText: search,
            fileSize: size,
            modified: modified
        )
    }

    /// `message.usage` of an assistant reply. Fast-mode replies get a "(fast)" model suffix so they price at 2×.
    private static func claudeUsage(_ message: [String: Any], timestamp: Any?) -> (key: UsageKey, usage: TokenUsage)? {
        guard let model = message["model"] as? String, model != "<synthetic>",
              let u = message["usage"] as? [String: Any] else { return nil }
        var usage = TokenUsage()
        usage.input = u["input_tokens"] as? Int ?? 0
        usage.cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
        usage.output = u["output_tokens"] as? Int ?? 0
        let written = u["cache_creation_input_tokens"] as? Int ?? 0
        if let split = u["cache_creation"] as? [String: Any] {
            usage.cacheWrite5m = split["ephemeral_5m_input_tokens"] as? Int ?? 0
            usage.cacheWrite1h = split["ephemeral_1h_input_tokens"] as? Int ?? 0
        }
        if usage.cacheWrite == 0 { usage.cacheWrite5m = written }
        if usage.isEmpty { return nil }
        let speed = (u["speed"] as? String) == "fast" ? " (fast)" : ""
        let day = date(timestamp).map(UsageKey.day(for:)) ?? "unknown"
        return (UsageKey(day: day, model: model + speed), usage)
    }

    /// Best effort: "-Users-me-Sites-app" -> "/Users/me/Sites/app" (lossy when names contain '-').
    static func decodeProjectDir(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Transcript

    static func transcript(_ url: URL) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var toolIndex: [String: Int] = [:]
        var seen = Set<String>()
        var attachmentCount = 0

        /// Base64 image / document blocks (`{"type":"image","source":{"type":"base64",...}}`).
        func embedded(_ content: Any?, prefix: String) -> (found: [Attachment], missing: Int) {
            var found: [Attachment] = []
            var missing = 0
            for b in content as? [[String: Any]] ?? [] {
                let type = b["type"] as? String
                guard type == "image" || type == "document" else { continue }
                let src = b["source"] as? [String: Any]
                guard (src?["type"] as? String) == "base64",
                      let data = src?["data"] as? String,
                      let mime = src?["media_type"] as? String
                else { missing += 1; continue }
                attachmentCount += 1
                let name = String(format: "%@-%02d.%@", prefix, attachmentCount, Attachment.fileExtension(forMime: mime))
                found.append(Attachment(id: "a\(attachmentCount)", name: name, source: .embedded(base64: data, mime: mime)))
            }
            return (found, missing)
        }

        forEachRecord(in: url) { rec in
            let type = rec["type"] as? String
            guard type == "user" || type == "assistant" || type == "system" else { return }
            if (rec["isSidechain"] as? Bool) == true { return }
            let uuid = rec["uuid"] as? String ?? UUID().uuidString
            guard seen.insert(uuid).inserted else { return }
            let ts = date(rec["timestamp"])

            if type == "system" {
                let subtype = rec["subtype"] as? String
                switch subtype {
                case "compact_boundary":
                    items.append(TranscriptItem(id: uuid, kind: .system, text: "── 對話已壓縮 ──", date: ts))
                case "api_error":
                    let msg = (rec["content"] as? String) ?? "API 錯誤"
                    items.append(TranscriptItem(id: uuid, kind: .system, text: msg, date: ts, isError: true))
                default:
                    break
                }
                return
            }

            let message = rec["message"] as? [String: Any]
            let content = message?["content"]

            if type == "user" {
                if (rec["isCompactSummary"] as? Bool) == true {
                    let cleaned = cleanUserContent(content)
                    var item = TranscriptItem(id: uuid, kind: .system, text: "對話摘要 (compact)", date: ts)
                    item.toolResult = cleaned.text
                    items.append(item)
                    return
                }
                if (rec["isMeta"] as? Bool) == true { return }

                if let blocks = content as? [[String: Any]] {
                    for b in blocks where (b["type"] as? String) == "tool_result" {
                        guard let toolId = b["tool_use_id"] as? String, let idx = toolIndex[toolId] else { continue }
                        items[idx].toolResult = toolResultText(b["content"])
                        items[idx].isError = (b["is_error"] as? Bool) ?? false
                        items[idx].attachments += embedded(b["content"], prefix: "tool").found
                    }
                    if isToolResultOnly(content) { return }
                }
                let cleaned = cleanUserContent(content)
                guard !cleaned.text.isEmpty || cleaned.imageCount > 0 else { return }
                if cleaned.isCommandOutput {
                    items.append(TranscriptItem(id: uuid, kind: .system, text: cleaned.text, date: ts))
                    return
                }
                if cleaned.text.hasPrefix("[Request interrupted") {
                    items.append(TranscriptItem(id: uuid, kind: .system, text: "⏹ 已中斷", date: ts))
                    return
                }
                var item = TranscriptItem(id: uuid, kind: .user, text: cleaned.text, date: ts)
                item.context = cleaned.context
                let images = embedded(content, prefix: "image")
                item.attachments = images.found
                item.imageCount = images.missing
                items.append(item)
                return
            }

            // assistant
            let model = message?["model"] as? String
            guard let blocks = content as? [[String: Any]] else {
                if let s = content as? String, !s.isEmpty {
                    items.append(TranscriptItem(id: uuid, kind: .assistant, text: s, date: ts, model: model))
                }
                return
            }
            for (i, b) in blocks.enumerated() {
                let bid = "\(uuid)-\(i)"
                switch b["type"] as? String {
                case "text":
                    let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    items.append(TranscriptItem(id: bid, kind: .assistant, text: t, date: ts, model: model))
                case "thinking":
                    let t = (b["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    items.append(TranscriptItem(id: bid, kind: .thinking, text: t, date: ts))
                case "tool_use":
                    let name = b["name"] as? String ?? "tool"
                    let input = b["input"] as? [String: Any] ?? [:]
                    var item = TranscriptItem(id: bid, kind: .tool, text: toolSummary(name: name, input: input), date: ts)
                    item.title = prettyToolName(name)
                    item.toolInput = prettyJSON(input)
                    if let toolId = b["id"] as? String { toolIndex[toolId] = items.count }
                    items.append(item)
                default:
                    continue
                }
            }
        }
        return items
    }

    private static func toolResultText(_ content: Any?) -> String {
        var text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { b -> String? in
                switch b["type"] as? String {
                case "text": return b["text"] as? String
                case "image": return "[圖片]"
                default: return nil
                }
            }.joined(separator: "\n")
        } else {
            text = ""
        }
        let limit = 20_000
        if text.count > limit { text = String(text.prefix(limit)) + "\n… (已截斷)" }
        return text
    }

    private static func prettyToolName(_ name: String) -> String {
        // mcp__server__tool -> server · tool
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2 { return "\(parts[0]) · \(parts[1...].joined(separator: "__"))" }
        }
        return name
    }

    private static func toolSummary(name: String, input: [String: Any]) -> String {
        let keys = ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt", "skill"]
        for k in keys {
            if let v = input[k] as? String, !v.isEmpty {
                let oneLine = v.replacingOccurrences(of: "\n", with: " ")
                return String(oneLine.prefix(160))
            }
        }
        return ""
    }

    private static func prettyJSON(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              var s = String(data: data, encoding: .utf8)
        else { return "\(obj)" }
        if s.count > 20_000 { s = String(s.prefix(20_000)) + "\n… (已截斷)" }
        return s
    }
}
