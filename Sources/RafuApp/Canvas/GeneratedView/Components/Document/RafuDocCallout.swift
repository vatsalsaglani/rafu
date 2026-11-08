import JSONRenderClient
import JSONRenderSwiftUI
import SwiftUI

/// `Callout`: a note, tip, decision, or risk. The tone is shown by an icon
/// and a word, never by color alone. Children draw below the title.
@JRComponent(
    "Callout",
    description:
        "A highlighted note. kind is note, tip, info, warning, risk or decision. Children (for example Markdown) hold the body; text is a one-line body.",
    slots: ["default"])
nonisolated struct RafuDocCallout: View {
    @JRProp(
        description: "Tone of the callout.",
        oneOf: ["note", "tip", "info", "warning", "risk", "decision"])
    var kind: String?
    @JRProp(description: "Optional title.") var title: String?
    @JRProp(description: "Optional one-line body.") var text: String?

    var body: some View {
        RafuDocCalloutView(
            tone: MDXCalloutTone(typeName: kind), title: title, text: text,
            children: jrContext.children)
    }
}

struct RafuDocCalloutView: View {
    let tone: MDXCalloutTone
    let title: String?
    let text: String?
    let children: JRChildren

    @Environment(\.rafuTheme) private var theme

    private var toneColor: Color {
        switch tone {
        case .note, .decision: theme.palette.accent
        case .tip: theme.palette.success
        case .info: theme.palette.info
        case .warning: theme.palette.warning
        case .risk: theme.palette.error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                Image(systemName: tone.systemImage)
                    .foregroundStyle(toneColor)
                    .accessibilityHidden(true)
                Text(title ?? tone.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                if title != nil {
                    Text(tone.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title.map { "\(tone.label): \($0)" } ?? tone.label)
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            RafuDocumentChildren(children: children)
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.cardBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(toneColor).frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous))
    }
}
