import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `DiffSummary`: changed files with added and removed line counts. The
/// numbers come from the spec; Rafu runs no Git command for it.
@JRComponent(
    "DiffSummary",
    description:
        "Changed files: files [{path, added, removed}], at most 200; path chips open files."
)
nonisolated struct RafuDiffSummary: View {
    @JRProp(description: "Rows of {path, added, removed}.") var files: [JSONRenderCore.JSONValue]

    @Environment(\.generatedViewBoardContext) private var board
    @Environment(\.jsonRenderTheme) private var theme

    struct Row {
        let path: String
        let added: Int
        let removed: Int
    }

    var body: some View {
        let rows = Self.rows(files)
        VStack(alignment: .leading, spacing: theme.space.s1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: theme.space.s2) {
                    RafuFileChip(path: row.path, line: nil, label: nil, board: board)
                    Spacer(minLength: theme.space.s2)
                    Text("+\(row.added)")
                        .foregroundStyle(theme.color.good)
                    Text("−\(row.removed)")
                        .foregroundStyle(theme.color.critical)
                }
                .font(theme.type.footnote.monospacedDigit())
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text("\(row.added) added, \(row.removed) removed"))
            }
            if rows.count > 1 {
                let added = rows.reduce(0) { $0 + $1.added }
                let removed = rows.reduce(0) { $0 + $1.removed }
                Text("\(rows.count) files, +\(added) −\(removed)")
                    .font(theme.type.caption.monospacedDigit())
                    .foregroundStyle(theme.color.textSecondary)
                    .accessibilityLabel(
                        Text("\(rows.count) files, \(added) lines added, \(removed) removed"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func rows(_ values: [JSONRenderCore.JSONValue]) -> [Row] {
        values.prefix(RafuKeyValue.rowLimit).compactMap { value in
            guard case .object(let members) = value, let path = members["path"]?.stringValue
            else { return nil }
            func count(_ key: String) -> Int {
                guard let number = members[key]?.numberValue, number.isFinite else { return 0 }
                return max(0, min(Int(number), 9_999_999))
            }
            return Row(path: path, added: count("added"), removed: count("removed"))
        }
    }
}
