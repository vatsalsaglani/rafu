import RafuCore
import SwiftUI

/// The summary on top of the Notes column, in each summary state:
/// - writing: a card with three still placeholder lines and Cancel;
/// - ready: SUMMARY, DECISIONS and ACTION ITEMS with citation chips, and
///   "Claude Code · 12:14" with "Make again";
/// - no agent: a muted row;
/// - failed: a row with the reason and "Try Again";
/// - older text: a row above the summary with "Make again";
/// - none: a muted row with "Make Summary".
/// There is no consent step: the summary is on by default and Settings ▸
/// Meetings turns it off.
struct MeetingSummaryBlock: View {
    let model: MeetingDetailModel
    let context: MeetingSummaryContext

    @Environment(\.rafuTheme) private var theme

    private var canMake: Bool { model.hasRunner && !model.hasNoReadyAgent && model.isReady }

    var body: some View {
        switch context.state {
        case .generating:
            MeetingSummaryWritingCard(cli: context.writingCLI, onCancel: context.cancel)
        case .ready:
            if let notes = model.summaryNotes {
                MeetingSummaryNotesCard(
                    notes: notes, model: model, canMake: canMake, onMake: context.make)
            } else {
                noneRow
            }
        case .stale:
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                MeetingSummaryStatusRow(
                    symbol: "clock.arrow.circlepath", tint: theme.palette.textMuted,
                    text: MeetingDetailPresentation.summaryStaleText, detail: nil,
                    actionTitle: canMake ? "Make again" : nil, action: context.make)
                if let notes = model.summaryNotes {
                    MeetingSummaryNotesCard(
                        notes: notes, model: model, canMake: false, onMake: context.make)
                }
            }
        case .unavailable:
            MeetingSummaryStatusRow(
                symbol: "sparkles", tint: theme.palette.textMuted,
                text: MeetingDetailPresentation.summaryNoAgentText, detail: nil,
                actionTitle: nil, action: {})
        case .failed(let error):
            MeetingSummaryStatusRow(
                symbol: "exclamationmark.triangle", tint: theme.palette.warning,
                text: MeetingDetailPresentation.summaryFailedText, detail: error.message,
                actionTitle: canMake ? "Try Again" : nil, action: context.make)
        case .none:
            noneRow
        }
    }

    private var noneRow: some View {
        MeetingSummaryStatusRow(
            symbol: "sparkles", tint: theme.palette.textMuted,
            text: MeetingDetailPresentation.summaryNoneText, detail: nil,
            actionTitle: canMake ? "Make Summary" : nil, action: context.make)
    }
}

/// A summary card: card fill, a subtle border, the dense card radius.
private struct MeetingSummaryCardSurface: ViewModifier {
    @Environment(\.rafuTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(RafuMetrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.palette.cardBackground,
                in: RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                    .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
            )
    }
}

/// "Claude Code writes the summary…", three still placeholder lines (no
/// shimmer, so Reduce Motion needs nothing more), and Cancel.
private struct MeetingSummaryWritingCard: View {
    let cli: MeetingAgentCLI
    let onCancel: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            HStack(spacing: RafuMetrics.space2) {
                ProgressView().controlSize(.small)
                Text(MeetingDetailPresentation.summaryWritingText(cli: cli))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: RafuMetrics.space2)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.accent)
                    .help("Stop writing the summary")
            }
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                ForEach([1.0, 0.9, 0.6], id: \.self) { fraction in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.palette.chipBackground)
                        .frame(height: 8)
                        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            length * fraction
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
        }
        .modifier(MeetingSummaryCardSurface())
    }
}

/// The summary, the decisions and the action items, and the footer.
private struct MeetingSummaryNotesCard: View {
    let notes: MeetingSummaryNotes
    let model: MeetingDetailModel
    let canMake: Bool
    let onMake: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let verified = MeetingDetailPresentation.verifiedSummaryTurns(notes)
        VStack(alignment: .leading, spacing: RafuMetrics.space4) {
            if !notes.summaryMarkdown.isEmpty {
                section("SUMMARY") {
                    MeetingAnswerMarkdown(
                        markdown: MeetingDetailPresentation.answerMarkdown(
                            notes.summaryMarkdown, verified: verified, refs: model.turnRefs,
                            names: model.names),
                        onCite: cite)
                    let chips = MeetingDetailPresentation.citationChips(
                        in: notes.summaryMarkdown, verified: verified, refs: model.turnRefs,
                        names: model.names)
                    if !chips.isEmpty {
                        MeetingCitationChips(chips: chips, isActive: true, onCite: cite)
                    }
                }
            }
            if !notes.decisions.isEmpty {
                section("DECISIONS") { items(notes.decisions, verified: verified) }
            }
            if !notes.actionItems.isEmpty {
                section("ACTION ITEMS") { items(notes.actionItems, verified: verified) }
            }
            HStack(spacing: RafuMetrics.space2) {
                Text(MeetingDetailPresentation.agentMeta(cli: notes.cli, date: notes.date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
                if canMake {
                    Button("Make again", action: onMake)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.accent)
                        .help("Write the summary again")
                }
            }
        }
        .modifier(MeetingSummaryCardSurface())
    }

    private func cite(_ turn: MeetingTurnID) {
        Task { await model.reveal(turn) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func items(_ items: [MeetingSummaryItem], verified: Set<MeetingTurnID>) -> some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                    Text("•")
                        .foregroundStyle(theme.palette.textMuted)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                        MeetingAnswerMarkdown(
                            markdown: itemMarkdown(item, verified: verified), onCite: cite)
                        let chips = MeetingDetailPresentation.chips(
                            for: item.citations, refs: model.turnRefs, names: model.names)
                        if !chips.isEmpty {
                            MeetingCitationChips(chips: chips, isActive: true, onCite: cite)
                        }
                    }
                }
            }
        }
    }

    /// "**Priya**: Send the release notes". The owner is escaped.
    private func itemMarkdown(_ item: MeetingSummaryItem, verified: Set<MeetingTurnID>)
        -> String
    {
        let text = MeetingDetailPresentation.answerMarkdown(
            item.text, verified: verified, refs: model.turnRefs, names: model.names)
        guard let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines),
            !owner.isEmpty
        else { return text }
        return "**\(MeetingDetailPresentation.escapedLinkLabel(owner))**: \(text)"
    }
}

/// One quiet summary row: a symbol, the text, an optional reason and an
/// optional action. No fill.
private struct MeetingSummaryStatusRow: View {
    let symbol: String
    let tint: Color
    let text: String
    let detail: String?
    let actionTitle: String?
    let action: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .foregroundStyle(theme.palette.textSecondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
