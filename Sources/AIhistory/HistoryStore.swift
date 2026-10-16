import Foundation
import Observation

@MainActor
@Observable
final class HistoryStore {
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var lastLoaded: Date?

    /// Summaries keyed by path, reused while the file's size and mtime are unchanged.
    @ObservationIgnored private var cache: [String: SessionSummary] = [:]
    /// Codex sub-agent rollouts per parent session id (their usage is folded into the parent).
    @ObservationIgnored private var subagentFiles: [String: [URL]] = [:]

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        let cache = self.cache
        Task.detached(priority: .userInitiated) {
            let files = HistoryParser.sessionFiles().map { ($0, Agent.claude) }
                + CodexParser.sessionFiles().map { ($0, Agent.codex) }
            var results = Self.index(files: files, cache: cache)
            // Codex keeps thread names in a separate index that changes without touching the rollout.
            let names = CodexParser.threadNames()
            for i in results.indices where results[i].agent == .codex {
                results[i].title = names[results[i].sessionId] ?? CodexParser.fallbackTitle(results[i].firstPrompt)
            }
            let indexed = results
            await MainActor.run {
                // Drop anything trashed while this reload was running.
                let existing = indexed.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
                self.cache = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
                let folded = Self.foldSubagents(existing)
                self.subagentFiles = folded.files
                self.sessions = folded.sessions.sorted { $0.sortDate > $1.sortDate }
                PriceBook.shared.seenModels = Set(self.sessions.flatMap { $0.usage.keys.map(\.model) })
                self.isLoading = false
                self.lastLoaded = Date()
            }
        }
    }

    /// Adds each sub-agent thread's usage to its parent and drops it from the list.
    nonisolated private static func foldSubagents(_ all: [SessionSummary]) -> (sessions: [SessionSummary], files: [String: [URL]]) {
        var listed = all.filter { !$0.isSubagent }
        var index: [String: Int] = [:]
        for (i, s) in listed.enumerated() where index[s.sessionId] == nil { index[s.sessionId] = i }
        var files: [String: [URL]] = [:]
        for sub in all where sub.isSubagent {
            guard let parent = sub.parentSessionId, let i = index[parent] else { continue }
            for (key, u) in sub.usage { listed[i].usage[key, default: TokenUsage()] += u }
            files[parent, default: []].append(sub.fileURL)
        }
        return (listed, files)
    }

    nonisolated private static func index(files: [(URL, Agent)], cache: [String: SessionSummary]) -> [SessionSummary] {
        let lock = NSLock()
        var out: [SessionSummary] = []
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let (url, agent) = files[i]
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = attrs?[.modificationDate] as? Date
            let summary: SessionSummary?
            if let cached = cache[url.path], cached.fileSize == size, cached.modified == mtime {
                summary = cached
            } else {
                summary = agent == .codex ? CodexParser.summarize(url) : HistoryParser.summarize(url)
            }
            if let summary {
                lock.lock()
                out.append(summary)
                lock.unlock()
            }
        }
        return out
    }

    /// Moves each session's transcript and related data to the Trash (recoverable from Finder).
    /// Returns the sessions that could not be moved.
    @discardableResult
    func trash(_ targets: [SessionSummary]) -> [(SessionSummary, Error)] {
        let fm = FileManager.default
        let claudeDir = HistoryParser.projectsRoot.deletingLastPathComponent()
        var failures: [(SessionSummary, Error)] = []
        var removed = Set<String>()

        for s in targets {
            do {
                try fm.trashItem(at: s.fileURL, resultingItemURL: nil)
                removed.insert(s.id)
            } catch {
                failures.append((s, error))
                continue
            }
            // Codex keeps a thread in its rollout, plus one rollout per auto-review sub-agent.
            guard s.agent == .claude else {
                for url in subagentFiles[s.sessionId] ?? [] {
                    try? fm.trashItem(at: url, resultingItemURL: nil)
                    cache[url.path] = nil
                }
                subagentFiles[s.sessionId] = nil
                continue
            }
            // Side data; best effort once the transcript itself is gone.
            let related = [
                s.fileURL.deletingPathExtension(),  // <id>/ with tool-results, subagents
                claudeDir.appendingPathComponent("file-history/\(s.sessionId)"),
                claudeDir.appendingPathComponent("session-env/\(s.sessionId)"),
            ]
            for url in related where fm.fileExists(atPath: url.path) {
                try? fm.trashItem(at: url, resultingItemURL: nil)
            }
        }

        sessions.removeAll { removed.contains($0.id) }
        for id in removed { cache[id] = nil }
        return failures
    }

    func count(for filter: SourceFilter) -> Int {
        sessions.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
    }

    /// Projects with session counts, restricted to the given filter.
    func projects(for filter: SourceFilter) -> [(path: String, name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for s in sessions where filter.matches(s) {
            counts[s.projectPath, default: 0] += 1
        }
        return counts
            .map { (path: $0.key, name: ($0.key as NSString).lastPathComponent, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func filtered(_ filter: SourceFilter, project: String?, query: String) -> [SessionSummary] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return sessions.filter { s in
            if !filter.matches(s) { return false }
            if let project, s.projectPath != project { return false }
            if terms.isEmpty { return true }
            let title = s.title.lowercased()
            return terms.allSatisfy { s.searchText.contains($0) || title.contains($0) }
        }
    }
}
