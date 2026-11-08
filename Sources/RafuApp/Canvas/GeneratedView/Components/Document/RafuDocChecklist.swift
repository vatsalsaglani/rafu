import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `Checklist`: a titled list of items with a done count. In a document the
/// items are read only. When `items` is bound with `$bindState`, a generated
/// view can toggle them; the whole array is written back.
@JRComponent(
    "Checklist",
    description:
        "A titled checklist. items is a list of {text, done}. Bind items with $bindState to let the user tick items.",
    slots: ["default"])
nonisolated struct RafuDocChecklist: View {
    @JRProp(description: "Optional title. Default: Checklist.") var title: String?
    @JRProp(description: "List of {text: string, done: boolean}.", bindable: true)
    var items: [JSONRenderCore.JSONValue]

    var body: some View {
        RafuDocChecklistView(
            title: title, items: items, binding: jrContext.bindings["items"],
            children: jrContext.children)
    }

    /// Bold, italic, code and links in an item; plain text when the
    /// Markdown does not parse.
    static func inlineMarkdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(source)
    }
}

struct RafuDocChecklistView: View {
    let title: String?
    let items: [JSONRenderCore.JSONValue]
    let binding: JSONPointer?
    let children: JRChildren

    @Environment(\.rafuTheme) private var theme
    @Environment(\.jrWriteBinding) private var writeBinding

    private struct Row {
        let text: String
        let done: Bool
    }

    private var rows: [Row] {
        items.compactMap { value in
            guard let object = value.objectValue, let text = object["text"]?.stringValue
            else { return nil }
            return Row(text: text, done: object["done"]?.boolValue ?? false)
        }
    }

    var body: some View {
        let rows = rows
        let done = rows.filter(\.done).count
        RafuDocumentFrame {
            RafuDocumentHeader(
                systemImage: "checklist", title: title ?? "Checklist",
                badge: rows.isEmpty ? nil : "\(done) of \(rows.count) done")
        } content: {
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    itemRow(row, index: index)
                }
                RafuDocumentChildren(children: children)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func itemRow(_ row: Row, index: Int) -> some View {
        let label = HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Image(systemName: row.done ? "checkmark.square.fill" : "square")
                .foregroundStyle(row.done ? theme.palette.accent : theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(RafuDocChecklist.inlineMarkdown(row.text))
                .font(.system(size: 13.5))
                .foregroundStyle(
                    row.done ? theme.palette.textSecondary : theme.palette.textPrimary
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if binding != nil {
            Button {
                toggle(index)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityValue(row.done ? "Done" : "Not done")
            .accessibilityAddTraits(.isToggle)
        } else {
            label
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityValue(row.done ? "Done" : "Not done")
        }
    }

    private func toggle(_ index: Int) {
        guard let pointer = binding, items.indices.contains(index),
            var object = items[index].objectValue
        else { return }
        object["done"] = .bool(!(object["done"]?.boolValue ?? false))
        var updated = items
        updated[index] = .object(object)
        writeBinding(pointer, .array(updated))
    }
}
