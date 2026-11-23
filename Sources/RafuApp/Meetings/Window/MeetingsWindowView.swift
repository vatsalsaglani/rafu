import RafuCore
import SwiftUI

/// The Meetings window (the `.windowView` hook): the meeting list on the
/// frame and the content on a raised deck card, like a workspace window.
/// It follows Settings ▸ Appearance ▸ Window background: in Frosted, one
/// behind-window blur and one tint lie under the frame. On macOS 15 it
/// shows the placeholder.
struct MeetingsWindowView: View {
    let feature: MeetingsFeature

    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @AppStorage(WindowSurfacePreference.styleKey) private var windowSurfaceStyle =
        WindowSurfacePreference.Style.solid.rawValue
    @AppStorage(WindowSurfacePreference.frostLevelKey) private var windowSurfaceFrost =
        WindowSurfacePreference.FrostLevel.balanced.rawValue
    @AppStorage(WindowSurfacePreference.frostContentKey) private var windowSurfaceFrostsContent =
        true
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let resolvedTheme = theme
        let surface = windowSurface(resolvedTheme)
        Group {
            if feature.availability.isAvailable {
                MeetingsWindowSplitView(feature: feature)
            } else {
                MeetingsPlaceholderView(availability: feature.availability)
            }
        }
        .background {
            // Frosted: the one blur and the one frame tint, below every
            // frame surface (which then paints nothing). Solid: nothing
            // here; the frame surfaces paint the frame.
            if surface.isFrosted {
                WindowFrostBackdrop(
                    tint: resolvedTheme.palette.appBackground,
                    tintOpacity: surface.tintOpacity
                )
                .ignoresSafeArea()
            }
        }
        .environment(\.rafuWindowSurface, surface)
        .rafuTheme(resolvedTheme)
        .preferredColorScheme(preferredColorScheme)
    }

    /// Resolved like a workspace window: Reduce Transparency and Increase
    /// Contrast force Solid.
    private func windowSurface(_ theme: RafuTheme) -> WindowSurfacePreference.Resolved {
        WindowSurfacePreference.resolve(
            style: windowSurfaceStyle,
            level: windowSurfaceFrost,
            frostsContent: windowSurfaceFrostsContent,
            isDark: theme.isDark,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )
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
            WorkbenchDeckSurface {
                MeetingsContentColumn(
                    feature: feature, model: model, commands: commands,
                    onDownload: { showsDownloadSheet = true },
                    onDelete: { deleteTarget = $0 }
                )
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .rafuDeckFill(theme.palette.editorBackground, .deck)
            }
            .padding(
                EdgeInsets(
                    top: RafuMetrics.space2, leading: RafuMetrics.deckInsetLeading,
                    bottom: RafuMetrics.deckInsetBottom, trailing: RafuMetrics.deckInsetTrailing)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // One frame fill under the list and the deck lane, so the deck's
        // shadow shows on the frame. Frosted: it paints nothing.
        .rafuFrameSurface(.app)
        .task(
            id: ReloadKey(
                revision: session.libraryRevision, live: session.liveMeeting,
                retry: model.retryToken)
        ) {
            guard let listed = await model.reload(from: feature.store) else { return }
            session.windowSelection = MeetingsWindowPresentation.validSelection(
                session.windowSelection, listed: listed, liveMeeting: session.liveMeeting,
                processing: Set(session.processing.keys))
            session.noteMeetingTitles(
                model.sections.flatMap(\.rows).map { ($0.id, $0.title) })
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
            feature.modelInstaller?.state(for: .whisperLargeV3)?.isInstalled == true
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

/// The content column: the banner, then the start page, the live body, the
/// processing or failed card, or the detail view for the selection.
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
            MeetingLiveBody(session: session, commands: commands, title: summary?.title)
        case .processing(let meeting):
            let title = MeetingsWorkspacePresentation.displayTitle(summary?.title ?? "")
            switch MeetingsWindowPresentation.processingDisplay(state: summary?.state, step: step) {
            case .running(let progress):
                MeetingProcessingCard(title: title, progress: progress) {
                    commands.cancelProcessing(meeting)
                }
            case .stopped(let reason):
                MeetingFailedCard(
                    title: title, reason: reason,
                    canDelete: summary != nil && commands.canDelete(meeting),
                    onRetry: { commands.retryProcessing(meeting) },
                    onDelete: { summary.map(onDelete) })
            }
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
