import RafuCore
import SwiftUI

/// The Meetings window (the `.windowView` hook): the meeting list on the
/// left and the content on the right. On macOS 15 it shows the placeholder.
struct MeetingsWindowView: View {
    let feature: MeetingsFeature

    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        Group {
            if feature.availability.isAvailable {
                MeetingsWindowSplitView(feature: feature)
            } else {
                MeetingsPlaceholderView(availability: feature.availability)
            }
        }
        .rafuTheme(theme)
        .preferredColorScheme(preferredColorScheme)
    }

    private var theme: RafuTheme {
        let _ = themeRevision
        return RafuThemeCatalog.resolved(identifier: themeChoice, systemScheme: systemScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        RafuThemeChoice(rawValue: themeChoice) == .system ? nil : theme.colorScheme
    }
}

/// The list column and the content column, with the rename and delete
/// dialogs and the model download sheet.
private struct MeetingsWindowSplitView: View {
    let feature: MeetingsFeature

    @State private var model = MeetingsWindowModel()
    @State private var showsDownloadSheet = false
    @State private var didCheckFirstUse = false
    @State private var renameTarget: MeetingSummaryRecord?
    @State private var deleteTarget: MeetingSummaryRecord?
    @Environment(\.rafuTheme) private var theme

    private var session: MeetingsSessionModel { feature.session }
    private var commands: MeetingsWindowCommands { MeetingsWindowCommands(session: session) }

    private struct ReloadKey: Hashable {
        var revision: Int
        var live: MeetingID?
        var retry: Int
    }

    var body: some View {
        HStack(spacing: 0) {
            MeetingsListColumn(
                feature: feature, model: model, commands: commands,
                onRename: beginRename, onDelete: { deleteTarget = $0 }
            )
            .frame(width: 240)
            .frame(maxHeight: .infinity, alignment: .top)
            .rafuFrameSurface(.sidebar)
            Divider()
            MeetingsContentColumn(
                feature: feature, model: model, commands: commands,
                onDownload: { showsDownloadSheet = true },
                onDelete: { deleteTarget = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.palette.editorBackground)
        }
        .task(
            id: ReloadKey(
                revision: session.libraryRevision, live: session.liveMeeting,
                retry: model.retryToken)
        ) {
            guard let listed = await model.reload(from: feature.store) else { return }
            session.windowSelection = MeetingsWindowPresentation.validSelection(
                session.windowSelection, listed: listed, liveMeeting: session.liveMeeting,
                processing: Set(session.processing.keys))
        }
        .onChange(of: session.liveMeeting) { old, new in
            if old == nil, let new { session.windowSelection = new }
        }
        .onAppear(perform: checkFirstUse)
        .sheet(isPresented: $showsDownloadSheet, onDismiss: markFirstUseShown) {
            if let sheet = feature.modelDownloadSheet { sheet(feature) }
        }
        .background {
            // The Rafu popups (not system alerts), on their own host view so
            // they never share a modifier with the download sheet.
            Color.clear
                .sheet(item: $renameTarget) { target in
                    RafuTextFieldPopup(
                        symbol: "pencil", title: "Rename Meeting",
                        subtitle: "Enter a new title for this meeting.", fieldLabel: "Title",
                        initialText: target.title, actionTitle: "Rename",
                        validate: {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Enter a title." : nil
                        },
                        cancel: { renameTarget = nil }
                    ) { title in
                        renameTarget = nil
                        guard title != target.title else { return }
                        Task {
                            await model.rename(
                                target.id, to: title, store: feature.store, session: session)
                        }
                    }
                }
                .sheet(item: $deleteTarget) { target in
                    RafuConfirmPopup(
                        symbol: "trash", title: "Delete this meeting?",
                        message: "The audio and the transcript are removed. You cannot undo this.",
                        actions: [
                            .init("Delete", isDestructive: true) {
                                deleteTarget = nil
                                commands.delete(target.id)
                            }
                        ]
                    ) {
                        deleteTarget = nil
                    }
                }
        }
    }

    private func beginRename(_ target: MeetingSummaryRecord) {
        renameTarget = target
    }

    private func checkFirstUse() {
        if session.windowSelection == nil, let live = session.liveMeeting {
            session.windowSelection = live
        }
        guard !didCheckFirstUse else { return }
        didCheckFirstUse = true
        let installed =
            feature.modelInstaller?.state(for: .nemotronEnglish1120)?.isInstalled == true
        if MeetingsFirstUseSheetRule.shouldShow(
            hasSheet: feature.modelDownloadSheet != nil,
            isAvailable: feature.availability.isAvailable, isModelInstalled: installed,
            defaults: .standard)
        {
            showsDownloadSheet = true
        }
    }

    private func markFirstUseShown() {
        MeetingsFirstUseSheetRule.markShown(defaults: .standard)
    }
}

/// The content column: the banner, then the start, live, processing or
/// detail view for the selection.
private struct MeetingsContentColumn: View {
    let feature: MeetingsFeature
    let model: MeetingsWindowModel
    let commands: MeetingsWindowCommands
    let onDownload: () -> Void
    let onDelete: (MeetingSummaryRecord) -> Void

    private var session: MeetingsSessionModel { feature.session }

    var body: some View {
        VStack(spacing: 0) {
            if let banner = MeetingsWindowPresentation.banner(
                startFailure: session.startFailure, recorderState: session.recorderState)
            {
                MeetingsStartFailureBanner(failure: banner, onDismiss: commands.dismissBanner)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        let selection = session.windowSelection
        let summary = model.summary(for: selection)
        let step = selection.flatMap { session.processing[$0] }
        switch MeetingsWindowPresentation.content(
            selection: selection, recorderState: session.recorderState, summary: summary,
            step: step)
        {
        case .start:
            MeetingsStartView(
                feature: feature, commands: commands, onDownload: onDownload,
                microphoneReader: MeetingsCoreAudioMicrophoneReader())
        case .live:
            MeetingsLiveView(session: session, commands: commands, title: summary?.title)
        case .processing(let meeting):
            MeetingsProcessingView(
                meeting: meeting, summary: summary, step: step, commands: commands,
                onDelete: { summary.map(onDelete) })
        case .detail(let meeting):
            if let hook = feature.meetingDetailView {
                hook(feature, meeting)
            } else {
                MeetingsPlaceholderView()
            }
        }
    }
}

/// A start failure or a recorder problem, with its reason, a System
/// Settings link for the two permission problems, and Dismiss.
struct MeetingsStartFailureBanner: View {
    let failure: MeetingsStartFailure
    let onDismiss: () -> Void

    @Environment(\.rafuTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.palette.warning)
                .accessibilityHidden(true)
            Text(failure.message)
                .foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let url = MeetingsWindowPresentation.systemSettingsURL(for: failure) {
                Button("Open System Settings") { openURL(url) }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Open Privacy & Security in System Settings")
            }
            Button("Dismiss", action: onDismiss)
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .help("Hide this message")
        }
        .padding(RafuMetrics.space3)
        .background(theme.palette.cardBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.palette.borderSubtle).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Problem")
    }
}
