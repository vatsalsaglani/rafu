import RafuCore
import SwiftUI

/// The body of a meeting tab. It shows what the Meetings window shows: the
/// detail view of a ready meeting, the live body while it records, the
/// processing card after Stop, or the failed card. The tab never sends the
/// user to the window.
struct MeetingsTabBodyView: View {
    let feature: MeetingsFeature
    let workspaceSession: WorkspaceSession
    let meeting: MeetingID

    @State private var summary: MeetingSummaryRecord?
    @State private var isLoaded = false
    @State private var confirmsDelete = false

    private var session: MeetingsSessionModel { feature.session }
    private var commands: MeetingsWindowCommands { MeetingsWindowCommands(session: session) }

    var body: some View {
        let content = MeetingsWorkspacePresentation.tabContent(
            summary: summary, isLoaded: isLoaded, meeting: meeting,
            recorder: session.recorderState, processing: session.processing[meeting])
        let title = MeetingsWorkspacePresentation.displayTitle(summary?.title ?? "")
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
            case .live:
                MeetingLiveBody(session: session, commands: commands, title: summary?.title)
            case .processing(let progress):
                MeetingProcessingCard(title: title, progress: progress) {
                    commands.cancelProcessing(meeting)
                }
            case .failed(let reason):
                MeetingFailedCard(
                    title: title, reason: reason, canDelete: commands.canDelete(meeting),
                    onRetry: { commands.retryProcessing(meeting) },
                    onDelete: { confirmsDelete = true })
            case .deleted:
                RafuPanelEmptyState(
                    icon: "trash",
                    title: MeetingsWorkspacePresentation.deletedMeetingMessage,
                    message: "Close this tab.",
                    compact: false
                ) {
                    Button("Close Tab") {
                        workspaceSession.closeAuxiliaryTab(.meeting(meeting))
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.libraryRevision) {
            let loaded = try? await feature.store?.summary(of: meeting)
            guard !Task.isCancelled else { return }
            summary = loaded ?? nil
            isLoaded = true
            if let summary {
                session.noteMeetingTitle(
                    meeting, MeetingsWorkspacePresentation.displayTitle(summary.title))
            }
        }
        .sheet(isPresented: $confirmsDelete) {
            // Cancel is the default button, so Return never deletes.
            RafuConfirmPopup(
                symbol: "trash",
                title: MeetingsWorkspacePresentation.deleteConfirmationTitle,
                message: MeetingsWorkspacePresentation.deleteConfirmationMessage,
                actions: [
                    .init("Delete", isDestructive: true) {
                        confirmsDelete = false
                        commands.delete(meeting)
                    }
                ]
            ) {
                confirmsDelete = false
            }
        }
    }
}
