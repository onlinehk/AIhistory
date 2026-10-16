import Foundation
import SwiftUI

/// Which coding agent wrote the history.
enum Agent: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "hexagon"
        }
    }

    var color: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .green
        }
    }
}

/// Which client started a session: Claude's `entrypoint` field, or Codex's `originator`.
enum SessionSource: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cli
    case vscode
    case desktop
    case jetbrains
    case sdk
    case other
    case codexCLI
    case codexVSCode
    case codexApp
    case codexSDK

    var id: String { rawValue }

    init(entrypoint: String?) {
        guard let e = entrypoint?.lowercased(), !e.isEmpty else {
            self = .other
            return
        }
        switch e {
        case "cli": self = .cli
        case "claude-vscode": self = .vscode
        case "claude-desktop": self = .desktop
        default:
            if e.contains("vscode") || e.contains("cursor") || e.contains("windsurf") {
                self = .vscode
            } else if e.contains("jetbrains") || e.contains("intellij") {
                self = .jetbrains
            } else if e.contains("desktop") {
                self = .desktop
            } else if e.hasPrefix("sdk") || e.contains("agent-sdk") {
                self = .sdk
            } else {
                self = .other
            }
        }
    }

    /// Codex `session_meta.originator`, e.g. "codex_vscode", "Codex Desktop", "codex_exec".
    init(codexOriginator: String?) {
        let o = (codexOriginator ?? "").lowercased()
        if o.contains("vscode") || o.contains("cursor") || o.contains("windsurf") {
            self = .codexVSCode
        } else if o.contains("desktop") || o.contains("app") {
            self = .codexApp
        } else if o.contains("sdk") {
            self = .codexSDK
        } else {
            self = .codexCLI
        }
    }

    var agent: Agent {
        switch self {
        case .codexCLI, .codexVSCode, .codexApp, .codexSDK: return .codex
        default: return .claude
        }
    }

    var label: String {
        switch self {
        case .cli: return "終端機 CLI"
        case .vscode: return "VS Code"
        case .desktop: return "Claude Desktop"
        case .jetbrains: return "JetBrains"
        case .sdk: return "Agent SDK"
        case .other: return "其他 / 未知"
        case .codexCLI: return "終端機 CLI"
        case .codexVSCode: return "VS Code"
        case .codexApp: return "Codex App"
        case .codexSDK: return "Codex SDK"
        }
    }

    var shortLabel: String {
        switch self {
        case .cli: return "CLI"
        case .vscode: return "VS Code"
        case .desktop: return "Desktop"
        case .jetbrains: return "JetBrains"
        case .sdk: return "SDK"
        case .other: return "其他"
        case .codexCLI: return "Codex CLI"
        case .codexVSCode: return "Codex VS Code"
        case .codexApp: return "Codex App"
        case .codexSDK: return "Codex SDK"
        }
    }

    var symbol: String {
        switch self {
        case .cli: return "terminal"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .desktop: return "macwindow"
        case .jetbrains: return "hammer"
        case .sdk: return "shippingbox"
        case .other: return "questionmark.circle"
        case .codexCLI: return "terminal"
        case .codexVSCode: return "chevron.left.forwardslash.chevron.right"
        case .codexApp: return "hexagon"
        case .codexSDK: return "shippingbox"
        }
    }

    var color: Color {
        switch self {
        case .cli: return .orange
        case .vscode: return .blue
        case .desktop: return .purple
        case .jetbrains: return .pink
        case .sdk: return .teal
        case .other: return .gray
        case .codexCLI: return .mint
        case .codexVSCode: return .cyan
        case .codexApp: return .green
        case .codexSDK: return .teal
        }
    }
}

struct SessionSummary: Identifiable, Hashable, Sendable {
    /// File path; unique even if a session id is reused across projects.
    var id: String { fileURL.path }
    let sessionId: String
    let fileURL: URL
    let projectPath: String
    var title: String
    let firstPrompt: String
    let startDate: Date?
    let endDate: Date?
    let promptCount: Int
    let source: SessionSource
    let rawEntrypoint: String?
    let gitBranch: String?
    let version: String?
    let model: String?
    /// Tokens per (local day, model), including sub-agent work.
    var usage: [UsageKey: TokenUsage] = [:]
    /// Codex auto-review / sub-agent threads are folded into their parent and not listed.
    var isSubagent = false
    var parentSessionId: String? = nil
    /// Lowercased title + prompts, used for search.
    let searchText: String
    let fileSize: Int64
    let modified: Date

    var projectName: String {
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    var sortDate: Date { endDate ?? modified }
    var agent: Agent { source.agent }

    var totalUsage: TokenUsage { usage.values.reduce(into: TokenUsage()) { $0 += $1 } }

    var usageByModel: [String: TokenUsage] {
        usage.reduce(into: [:]) { $0[$1.key.model, default: TokenUsage()] += $1.value }
    }
}

/// Token counts, split the way both providers bill them.
struct TokenUsage: Hashable, Sendable {
    /// Input not served from cache.
    var input = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    /// Includes reasoning / thinking tokens (billed as output by both providers).
    var output = 0
    /// The reasoning part of `output`, when reported.
    var reasoning = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var allInput: Int { input + cacheRead + cacheWrite }
    var total: Int { allInput + output }
    var isEmpty: Bool { total == 0 }
    /// Share of input served from cache.
    var cacheHitRate: Double { allInput > 0 ? Double(cacheRead) / Double(allInput) : 0 }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.output += rhs.output
        lhs.reasoning += rhs.reasoning
    }
}

struct UsageKey: Hashable, Sendable {
    /// Local calendar day, "yyyy-MM-dd".
    let day: String
    let model: String

    static func day(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(forDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Sidebar rows: everything, one agent, or one client.
enum SourceFilter: Hashable {
    case all
    case agent(Agent)
    case source(SessionSource)

    func matches(_ s: SessionSummary) -> Bool {
        switch self {
        case .all: return true
        case .agent(let a): return s.agent == a
        case .source(let src): return s.source == src
        }
    }

    var title: String {
        switch self {
        case .all: return "全部對話"
        case .agent(let a): return "全部 \(a.label)"
        case .source(let s): return "\(s.agent.label) · \(s.label)"
        }
    }
}

/// An image or file attached to a message or produced by a tool.
struct Attachment: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// Stored inside the history file itself.
        case embedded(base64: String, mime: String)
        /// Only a path was recorded; the file may since have been deleted.
        case file(path: String)
    }

    let id: String
    let name: String
    let source: Source

    var isImage: Bool {
        switch source {
        case .embedded(_, let mime): return mime.hasPrefix("image/")
        case .file(let path):
            return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
                .contains((path as NSString).pathExtension.lowercased())
        }
    }

    var isAvailable: Bool {
        if case .file(let path) = source { return FileManager.default.fileExists(atPath: path) }
        return true
    }

    var filePath: String? {
        if case .file(let path) = source { return path }
        return nil
    }

    func data() -> Data? {
        switch source {
        case .embedded(let b64, _): return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        case .file(let path): return FileManager.default.contents(atPath: path)
        }
    }

    static func fileExtension(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "application/pdf": return "pdf"
        default: return mime.split(separator: "/").last.map(String.init) ?? "bin"
        }
    }

    /// Parses `data:image/png;base64,....`.
    static func fromDataURL(_ url: String, id: String, baseName: String) -> Attachment? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(7))
        let b64 = String(url[url.index(after: comma)...])
        return Attachment(id: id, name: "\(baseName).\(fileExtension(forMime: mime))", source: .embedded(base64: b64, mime: mime))
    }
}

struct TranscriptItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case user
        case assistant
        case thinking
        case tool
        case system
    }

    let id: String
    let kind: Kind
    var text: String
    var date: Date?
    /// For tool calls: tool name. For user messages: IDE context chips.
    var title: String?
    var context: [String] = []
    /// Images the history mentions but no longer has the data for.
    var imageCount: Int = 0
    var attachments: [Attachment] = []
    var toolInput: String?
    var toolResult: String?
    var isError: Bool = false
    var model: String?
}
