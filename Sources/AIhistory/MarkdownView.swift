import SwiftUI

/// Lightweight block-level Markdown: fenced code, headings, tables, quotes; inline styles via AttributedString.
struct MarkdownView: View {
    let text: String
    /// Resolves relative file links (usually the session's project folder).
    var baseDirectory: String? = nil

    private enum Block: Hashable {
        case heading(Int, String)
        case code(String)
        case table(String)
        case quote(String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            LocalLinks.open(url) ? .handled : .systemAction
        })
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .table(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(.callout, design: .monospaced))
            }
        case .quote(let s):
            HStack(spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 3)
                inline(s).foregroundStyle(.secondary)
            }
        case .paragraph(let s):
            inline(s)
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let source = s.contains("](") ? LocalLinks.rewriteForParsing(s, base: baseDirectory) : s
        if let attr = try? AttributedString(markdown: source, options: options) {
            return Text(attr)
        }
        return Text(s)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var para: [String] = []
        var code: [String]?
        var table: [String] = []
        var quote: [String] = []

        func flush() {
            if !para.isEmpty { result.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !table.isEmpty { result.append(.table(table.joined(separator: "\n"))); table = [] }
            if !quote.isEmpty { result.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    result.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if trimmed.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(trimmed)
                continue
            } else if !table.isEmpty {
                flush()
            }
            if trimmed.hasPrefix(">") {
                if !para.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            } else if !quote.isEmpty {
                flush()
            }
            if let level = headingLevel(trimmed) {
                flush()
                result.append(.heading(level, String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed == "---" || trimmed == "***" {
                flush()
                continue
            }
            // Bullet markers read better as a dot.
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = String(line.prefix { $0 == " " })
                para.append(indent + "• " + trimmed.dropFirst(2))
            } else {
                para.append(line)
            }
        }
        if let code { result.append(.code(code.joined(separator: "\n"))) }
        flush()
        return result
    }

    private func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }
}
