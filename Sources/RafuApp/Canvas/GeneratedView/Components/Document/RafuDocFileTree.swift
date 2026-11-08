import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `FileTree`: planned or finished file changes, nested by depth.
@JRComponent(
    "FileTree",
    description:
        "A list of file paths with an optional action and note. entries is a list of {path, depth?, action? add|modify|delete|rename|move, note?}.",
    slots: ["default"])
nonisolated struct RafuDocFileTree: View {
    @JRProp(description: "Optional title. Default: Files.") var title: String?
    @JRProp(description: "List of {path, depth, action, note}.")
    var entries: [JSONRenderCore.JSONValue]

    var body: some View {
        RafuDocFileTreeView(title: title, entries: entries, children: jrContext.children)
    }
}

struct RafuDocFileTreeView: View {
    let title: String?
    let entries: [JSONRenderCore.JSONValue]
    let children: JRChildren

    @Environment(\.rafuTheme) private var theme

    private struct Entry {
        let path: String
        let depth: Int
        let action: String?
        let note: String?
    }

    private var rows: [Entry] {
        entries.compactMap { value in
            guard let object = value.objectValue, let path = object["path"]?.stringValue
            else { return nil }
            let depth = max(0, min(16, Int(object["depth"]?.numberValue ?? 0)))
            return Entry(
                path: path, depth: depth, action: object["action"]?.stringValue,
                note: object["note"]?.stringValue)
        }
    }

    var body: some View {
        let rows = rows
        RafuDocumentFrame {
            RafuDocumentHeader(systemImage: "folder", title: title ?? "Files", badge: nil)
        } content: {
            VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                        Image(systemName: entry.path.hasSuffix("/") ? "folder" : "doc")
                            .foregroundStyle(theme.palette.textSecondary)
                            .accessibilityHidden(true)
                        if let action = entry.action {
                            Text(action)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                        Text(entry.path)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(theme.palette.textPrimary)
                        if let note = entry.note {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.palette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, CGFloat(entry.depth) * 16)
                    .accessibilityElement(children: .combine)
                }
                RafuDocumentChildren(children: children)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}
