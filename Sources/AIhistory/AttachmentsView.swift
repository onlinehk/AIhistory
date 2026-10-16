import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Thumbnails for images and chips for files, wrapped onto as many lines as needed.
struct AttachmentsView: View {
    let attachments: [Attachment]
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        FlowLayout(spacing: 6, alignment: alignment) {
            ForEach(attachments) { a in
                if a.isImage && a.isAvailable {
                    ImageThumbnail(attachment: a)
                } else {
                    FileChip(attachment: a)
                }
            }
        }
    }
}

private struct ImageThumbnail: View {
    let attachment: Attachment

    /// Scale into 220×140 without enlarging small images.
    static func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 120, height: 90) }
        let scale = min(220 / size.width, 140 / size.height, 1)
        return CGSize(width: max(size.width * scale, 24), height: max(size.height * scale, 24))
    }
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                let size = Self.fitted(image.size)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(ProgressView().controlSize(.small))
                    .frame(width: 120, height: 90)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { AttachmentActions.save([attachment]) } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("另存為…")
                .padding(4)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture { AttachmentActions.open(attachment) }
        .contextMenu { AttachmentActions.menu(for: attachment) }
        .help("\(attachment.name)：撳一下用預設 app 開啟")
        .task(id: attachment.id) {
            let a = attachment
            image = await Task.detached(priority: .utility) { a.data().flatMap(NSImage.init(data:)) }.value
        }
    }
}

private struct FileChip: View {
    let attachment: Attachment

    var body: some View {
        let available = attachment.isAvailable
        Menu {
            AttachmentActions.menu(for: attachment)
        } label: {
            HStack(spacing: 5) {
                if let path = attachment.filePath, available {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: attachment.isImage ? "photo" : "doc")
                }
                Text(attachment.name).lineLimit(1).truncationMode(.middle)
                if !available {
                    Text("已不存在").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .foregroundStyle(available ? .primary : .secondary)
        .help(attachment.filePath ?? attachment.name)
    }
}

enum AttachmentActions {
    @ViewBuilder
    static func menu(for a: Attachment) -> some View {
        if a.isAvailable {
            Button("開啟") { open(a) }
            Button("另存為…") { save([a]) }
            if a.isImage {
                Button("拷貝圖片") { copyImage(a) }
            }
            if let path = a.filePath {
                Button("喺 Finder 顯示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        } else {
            Text("原本嘅檔案已經唔存在")
        }
        if let path = a.filePath {
            Divider()
            Button("拷貝路徑") { Clipboard.copy(path) }
        }
    }

    /// Embedded data is written to a temp file first so the default app can open it.
    static func open(_ a: Attachment) {
        if let path = a.filePath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        guard let data = a.data() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AIhistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(a.name)")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    static func copyImage(_ a: Attachment) {
        guard let data = a.data(), let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// One attachment: a save panel. Several: pick a folder and write them all into it.
    static func save(_ attachments: [Attachment], folderName: String? = nil) {
        let available = attachments.filter(\.isAvailable)
        guard !available.isEmpty else { return }

        if available.count == 1, folderName == nil, let a = available.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = a.name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            write(a, to: url)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "儲存到呢度"
        panel.message = "揀一個資料夾儲存 \(available.count) 個附件"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, var dir = panel.url else { return }
        if let folderName {
            dir.appendPathComponent(sanitize(folderName), isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var used = Set<String>()
        for a in available {
            write(a, to: dir.appendingPathComponent(uniqueName(a.name, used: &used)))
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private static func write(_ a: Attachment, to url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        if let path = a.filePath {
            try? fm.copyItem(at: URL(fileURLWithPath: path), to: url)
        } else if let data = a.data() {
            try? data.write(to: url)
        }
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while used.contains(candidate) {
            candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n")).joined(separator: "-")
        return String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
    }
}

/// Left-to-right wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
