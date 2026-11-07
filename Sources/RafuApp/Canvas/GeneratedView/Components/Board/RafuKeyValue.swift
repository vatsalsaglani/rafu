import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `KeyValue`: a two-column list of facts. At most 200 rows draw.
@JRComponent(
    "KeyValue", description: "Two-column facts: items [{key, value}], at most 200 rows.")
nonisolated struct RafuKeyValue: View {
    @JRProp(description: "Rows of {key, value}; value is a string or number.")
    var items: [JSONRenderCore.JSONValue]

    @Environment(\.jsonRenderTheme) private var theme

    static let rowLimit = 200

    var body: some View {
        Grid(
            alignment: .leadingFirstTextBaseline, horizontalSpacing: theme.space.s3,
            verticalSpacing: theme.space.s1
        ) {
            ForEach(Array(Self.rows(items).enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.key)
                        .font(theme.type.footnote)
                        .foregroundStyle(theme.color.textSecondary)
                        .lineLimit(2)
                    Text(row.value)
                        .font(theme.type.body.monospacedDigit())
                        .foregroundStyle(theme.color.text)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .gridColumnAlignment(.leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func rows(_ items: [JSONRenderCore.JSONValue]) -> [(key: String, value: String)] {
        items.prefix(rowLimit).compactMap { item in
            guard case .object(let members) = item else { return nil }
            let key = members["key"].map(RafuStat.text) ?? ""
            let value = members["value"].map(RafuStat.text) ?? "—"
            return (key, value)
        }
    }
}
