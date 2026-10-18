import SwiftUI

/// Agents seen through hooks that run outside Rafu (another terminal app or
/// an editor), listed under the open windows in the notch's Ensembles
/// section. Rows are information only: Rafu cannot focus another app's
/// session, so a row offers no action. Hidden when there are none.
struct TrackedAgentsNotchView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let rows = model.externalAgentRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Other agents")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ink.muted)
                    .padding(.leading, RafuMetrics.space2)
                ForEach(rows) { row in
                    TrackedAgentNotchRow(row: row)
                }
            }
            .padding(.leading, RafuMetrics.space2)
        }
    }
}

/// One outside agent: vendor icon, folder name, and state as a glyph plus a
/// word, so state never rests on colour alone.
private struct TrackedAgentNotchRow: View {
    let row: NotchAgentRow
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            AgentIconView(cli: row.cli, size: 14)
                .accessibilityHidden(true)
            Text(row.title)
                .font(.system(size: 11))
                .foregroundStyle(ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: RafuMetrics.space2)
            Image(systemName: row.phase.symbol)
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text(row.phase.label)
                .font(.system(size: 10, weight: row.phase.needsAttention ? .semibold : .regular))
        }
        .foregroundStyle(row.phase.needsAttention ? ink.accent : ink.secondary)
        .padding(.horizontal, RafuMetrics.space2)
        .frame(height: 24)
        .help("\(row.cli.displayName) in \(row.title), outside Rafu")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(row.title), \(row.cli.displayName), outside Rafu, \(row.phase.label)")
    }
}
