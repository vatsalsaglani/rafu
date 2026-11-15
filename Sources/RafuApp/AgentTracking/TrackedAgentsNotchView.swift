import SwiftUI

/// Agents seen through hooks that run outside Rafu (another terminal app or
/// an editor), listed under the open windows in the notch's Agents section
/// as Cider-style cards (`CompanionAgentCardView`). Cards are information
/// only: Rafu cannot focus another app's session, so a card offers no
/// action. Hidden when there are none.
struct TrackedAgentsNotchView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let rows = model.externalAgentRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: CompanionChromeMetrics.sectionSpacing) {
                Text("Other agents")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ink.muted)
                    .padding(.leading, RafuMetrics.space2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(rows) { row in
                    TrackedAgentNotchRow(row: row, among: rows)
                }
            }
        }
    }
}

/// One outside agent as a card, with the store's clock for "Last seen".
/// `among` is the list it is shown in, to decide whether a short session
/// suffix is needed to tell two cards apart.
struct TrackedAgentNotchRow: View {
    let row: NotchAgentRow
    var among: [NotchAgentRow] = []

    var body: some View {
        CompanionAgentCardView(
            row: row,
            showsSessionSuffix: CompanionAgentCardContent.showsSessionSuffix(row, among: among),
            now: AgentActivityStore.shared.now)
    }
}
