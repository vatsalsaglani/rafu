import RafuWidgetShared
import SwiftUI
import WidgetKit

/// The Board widget: every connected agent on one card, each with its
/// Hundred grid and its Seven columns. Extra large puts them side by side
/// in each row; extra large portrait (macOS 27) stacks the grid above the
/// columns. Everything it says comes from `WidgetBoardPresentation`.
///
/// It draws with the same `HundredGrid` and `SevenChartArea` the Hundred
/// and Seven widgets use (`WidgetDotDrawing.swift`): `Canvas` layers, no
/// view per dot, the usage dots `widgetAccentable()`, hierarchy from
/// opacity and shape, and no animation.
struct UsageBoardView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    private var presentation: WidgetBoardPresentation {
        WidgetBoardPresentation.make(snapshot: entry.snapshot, now: entry.date)
    }

    private var isPortrait: Bool {
        // See `UsageBoardWidget.families`: macOS 27 SDK only.
        #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                return family == .systemExtraLargePortrait
            }
        #endif
        return false
    }

    var body: some View {
        let presentation = presentation
        let ink = WidgetInk(inks: entry.snapshot?.inks, palette: presentation.palette)
        Group {
            switch presentation.content {
            case .notConnected(let reason):
                UsageNotConnectedView(reason: reason, systemImage: "square.grid.3x3")
            case .providers(let rows, _):
                VStack(alignment: .leading, spacing: 6) {
                    BoardHeader(updatedAt: presentation.updatedAt)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        BoardRowView(row: row, ink: ink, now: entry.date, portrait: isPortrait)
                            .frame(maxHeight: .infinity)
                    }
                    BoardFooter(moreText: presentation.moreText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// "Agent usage" and the time the app wrote the snapshot.
private struct BoardHeader: View {
    let updatedAt: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Agent usage")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let updatedAt {
                Text("Updated \(updatedAt, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// One legend for the board, and "+N more" when agents did not fit.
private struct BoardFooter: View {
    let moreText: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(
                "1 dot = 1% of a weekly limit · ring = projected by reset · outlined = time gone · dashed line = pace"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            if let moreText {
                Text(moreText)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// One agent: the text column, the Hundred grid, and the Seven columns.
private struct BoardRowView: View {
    let row: WidgetBoardRow
    let ink: WidgetInk
    let now: Date
    let portrait: Bool

    var body: some View {
        if portrait {
            VStack(alignment: .leading, spacing: 4) {
                BoardRowText(row: row, ink: ink, now: now, compact: true)
                BoardHundred(row: row, ink: ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SevenChartArea(card: row.seven, ink: ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                BoardRowText(row: row, ink: ink, now: now, compact: false)
                    .frame(width: 168, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                BoardHundred(row: row, ink: ink)
                    .frame(maxHeight: .infinity)
                SevenChartArea(card: row.seven, ink: ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The Hundred grid, or the token summary of a local estimate.
private struct BoardHundred: View {
    let row: WidgetBoardRow
    let ink: WidgetInk

    var body: some View {
        if let dots = row.hundred.dots {
            HundredGrid(
                dots: dots, marker: row.hundred.elapsedMarkerIndex, shape: row.shape, ink: ink
            )
            .opacity(row.isDimmed ? 0.45 : 1)
        } else {
            HundredLocalEstimateView(tokenSummary: nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// Name, headline, "Day N of 7", today, pace sentence, and countdown. The
/// compact (portrait) form puts them on two lines. A local estimate's
/// token summary shows in `SevenChartArea`, not here.
private struct BoardRowText: View {
    let row: WidgetBoardRow
    let ink: WidgetInk
    let now: Date
    let compact: Bool
    @Environment(\.colorScheme) private var scheme

    private var detail: some View {
        HStack(spacing: 4) {
            if let dayText = row.hundred.dayText { Text(dayText) }
            if !row.isDimmed, let todayText = row.hundred.todayText {
                Text("·")
                Text(todayText).monospacedDigit()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var statusLine: some View {
        Text(row.status.longText(now: now))
            .font(.caption2.weight(row.status.level == .normal ? .regular : .semibold))
            .foregroundStyle(ink.levelColor(row.status.level, scheme: scheme))
            .lineLimit(compact ? 1 : 2)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: !compact)
    }

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    SevenHeadline(card: row.seven, size: 18)
                    Spacer(minLength: 4)
                    detail
                }
                HStack(spacing: 6) {
                    statusLine
                    Spacer(minLength: 2)
                    SevenResetCountdown(resetsAt: row.isDimmed ? nil : row.hundred.resetsAt)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                SevenHeadline(card: row.seven, size: 24)
                detail
                Spacer(minLength: 2)
                statusLine
                SevenResetCountdown(resetsAt: row.isDimmed ? nil : row.hundred.resetsAt)
            }
        }
    }
}
