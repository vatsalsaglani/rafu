import RafuCore
import SwiftUI

/// The body of a meeting tab. A ready meeting shows the detail view that the
/// detail package registered. A live, processing or failed meeting shows its
/// state and a button to open the Meetings window.
struct MeetingsTabBodyView: View {
    let feature: MeetingsFeature
    let workspaceSession: WorkspaceSession
    let meeting: MeetingID

    @State private var summary: MeetingSummaryRecord?
    @State private var isLoaded = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.rafuTheme) private var theme

    private var session: MeetingsSessionModel { feature.session }

    var body: some View {
        let content = MeetingsWorkspacePresentation.tabContent(
            summary: summary, isLoaded: isLoaded, meeting: meeting,
            recorder: session.recorderState, elapsed: session.liveElapsed,
            processing: session.processing[meeting])
        Group {
            switch content {
            case .loading:
                Color.clear
            case .detail:
                if let hook = feature.meetingDetailView {
                    hook(feature, meeting)
                } else {
                    MeetingsPlaceholderView()
                }
            case .status(let badge, let line, let canRetry):
                status(badge: badge, line: line, canRetry: canRetry)
            case .deleted:
                RafuPanelEmptyState(
                    icon: "trash",
                    title: MeetingsWorkspacePresentation.deletedMeetingMessage,
                    message: "Close this tab.",
                    compact: false
                ) {
                    Button("Close tab") {
                        workspaceSession.closeAuxiliaryTab(.meeting(meeting))
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.libraryRevision) {
            let loaded = try? await feature.store?.summary(of: meeting)
            guard !Task.isCancelled else { return }
            summary = loaded ?? nil
            isLoaded = true
        }
    }

    private func status(badge: MeetingsStatusBadge, line: String?, canRetry: Bool) -> some View {
        VStack(spacing: RafuMetrics.space3) {
            Image(systemName: badge.symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(badge.word)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
            if let line {
                Text(line)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: RafuMetrics.space2) {
                if canRetry {
                    Button("Try again") { session.retryProcessing(meeting) }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                }
                Button("Open in Meetings") {
                    if !MeetingsWindowOpener.shared.open(selecting: meeting) {
                        session.windowSelection = meeting
                        openWindow(id: MeetingsWindowRoot.windowID)
                    }
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .padding(RafuMetrics.utilityBodyInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }
}
