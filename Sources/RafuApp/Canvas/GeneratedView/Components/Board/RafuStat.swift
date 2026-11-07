import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `Stat`: one figure with its label, an optional unit and change.
@JRComponent(
    "Stat",
    description:
        "One key figure: label, value (string or number), optional unit, delta (\"+12%\", \"-3\") and intent."
)
nonisolated struct RafuStat: View {
    @JRProp(description: "What the figure measures.") var label: String
    @JRProp(description: "The figure, a string or a number.") var value: JSONRenderCore.JSONValue
    @JRProp(description: "The change, for example \"+12%\" or \"-3\".") var delta: String?
    @JRProp(description: "The unit after the value.") var unit: String?
    @JRProp(oneOf: ["neutral", "info", "good", "warning", "critical"]) var intent: String?

    @Environment(\.jsonRenderTheme) private var theme

    var body: some View {
        let intent = GeneratedViewIntent(intent)
        VStack(alignment: .leading, spacing: theme.space.s1) {
            Text(label)
                .font(theme.type.footnote)
                .foregroundStyle(theme.color.textSecondary)
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s1) {
                Text(Self.text(value))
                    .font(theme.type.display.monospacedDigit())
                    .foregroundStyle(theme.color.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(theme.type.body)
                        .foregroundStyle(theme.color.textSecondary)
                }
            }
            if let delta, !delta.isEmpty {
                HStack(spacing: 3) {
                    if let symbol = Self.arrow(delta) {
                        Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                    }
                    Text(delta).font(theme.type.caption.monospacedDigit())
                    if let symbol = intent.symbol {
                        Image(systemName: symbol).font(.system(size: 9))
                    }
                }
                .foregroundStyle(intent.color(theme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(
            Text(
                [Self.text(value), unit ?? "", delta.map { "change \($0)" } ?? "", intent.word]
                    .filter { !$0.isEmpty }.joined(separator: ", ")))
    }

    static func text(_ value: JSONRenderCore.JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number, .bool: value.jsString
        default: "—"
        }
    }

    static func arrow(_ delta: String) -> String? {
        let trimmed = delta.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("−") { return "arrow.down" }
        if trimmed.hasPrefix("+") { return "arrow.up" }
        return nil
    }
}
