import Foundation
import AppKit

/// Markdown links in replies that point at files on this Mac, e.g. `[PDF 版](/Users/me/out/quote.pdf)`
/// or `[UserController.php](app/Http/Controllers/UserController.php:48)`.
enum LocalLinks {
    /// Generated deliverables worth offering as downloads (source files stay as plain links).
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "rtf", "pages", "xls", "xlsx", "csv", "numbers", "ppt", "pptx", "key",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp", "ico", "icns",
        "mp4", "mov", "m4v", "webm", "mp3", "wav", "m4a",
        "zip", "tar", "gz", "tgz", "7z", "rar", "dmg", "pkg", "ipa", "apk", "epub",
    ]

    private static let linkPattern = try! NSRegularExpression(pattern: #"\]\(\s*(<[^>]+>|[^)\s]+)(?:\s+"[^"]*")?\s*\)"#)

    /// Absolute path for a link destination, or nil for web links, anchors and other schemes.
    static func resolve(_ destination: String, base: String?) -> String? {
        var dest = destination.trimmingCharacters(in: .whitespaces)
        if dest.hasPrefix("<"), dest.hasSuffix(">") { dest = String(dest.dropFirst().dropLast()) }
        if dest.hasPrefix("file://") {
            dest = URL(string: dest)?.path ?? String(dest.dropFirst(7))
        } else if dest.contains("://") || dest.hasPrefix("#") || dest.hasPrefix("mailto:") || dest.hasPrefix("app:") {
            return nil
        }
        dest = dest.removingPercentEncoding ?? dest
        // Drop "#L48" anchors and ":48" / ":48:3" line suffixes.
        if let hash = dest.firstIndex(of: "#") { dest = String(dest[..<hash]) }
        dest = dest.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
        guard !dest.isEmpty else { return nil }
        if dest.hasPrefix("~") { return (dest as NSString).expandingTildeInPath }
        if dest.hasPrefix("/") { return dest }
        guard let base, !base.isEmpty else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent(dest).standardizedFileURL.path
    }

    /// Rewrites local link destinations to percent-encoded `file://` URLs so the Markdown parser
    /// keeps them (raw paths with spaces or CJK characters would otherwise be dropped).
    static func rewriteForParsing(_ markdown: String, base: String?) -> String {
        let ns = markdown as NSString
        var result = markdown
        for match in linkPattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            let dest = ns.substring(with: match.range(at: 1))
            guard let path = resolve(dest, base: base) else { continue }
            let url = URL(fileURLWithPath: path).absoluteString
            let full = match.range(at: 0)
            if let r = Range(full, in: result) {
                result.replaceSubrange(r, with: "](\(url))")
            }
        }
        return result
    }

    /// Linked document-type files in a reply, deduplicated, as attachments.
    static func attachments(in markdown: String, base: String?, idPrefix: String) -> [Attachment] {
        let ns = markdown as NSString
        var seen = Set<String>()
        var out: [Attachment] = []
        for match in linkPattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            guard let path = resolve(ns.substring(with: match.range(at: 1)), base: base),
                  documentExtensions.contains((path as NSString).pathExtension.lowercased()),
                  seen.insert(path).inserted
            else { continue }
            out.append(Attachment(id: "\(idPrefix)-\(out.count)", name: (path as NSString).lastPathComponent,
                                  source: .file(path: path)))
        }
        return out
    }

    /// Adds linked documents to each assistant reply.
    static func attachLinkedFiles(to items: inout [TranscriptItem], base: String?) {
        for i in items.indices where items[i].kind == .assistant && items[i].text.contains("](") {
            items[i].attachments += attachments(in: items[i].text, base: base, idPrefix: "link-\(items[i].id)")
        }
    }

    /// Opens `file://` links with the default app; lets the system handle web links.
    static func open(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
        return true
    }
}
