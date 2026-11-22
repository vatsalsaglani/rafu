import AppKit
import Observation
import RafuCore
import SwiftUI

/// The floating recording bar: a small capsule panel that the user can
/// move, with the state shape and word, the time, Pause or Resume, and
/// Stop. It shows only while a recording runs or is paused, and only when
/// the user turned it on from the menu bar item (default off;
/// `MeetingsStatusPolicy.showsFloatingBar`).
///
/// The panel never takes key focus from the call app: it is
/// non-activating and becomes key only if a control needs it.
@MainActor
final class MeetingsFloatingBarController {
    private let session: MeetingsSessionModel
    private let setting: MeetingsFloatingBarSetting
    private var panel: MeetingsFloatingBarPanel?
    /// The place the user moved the bar to, for this run only.
    private var movedOrigin: CGPoint?

    private static let size = MeetingsFloatingBarGeometry.size

    init(session: MeetingsSessionModel, setting: MeetingsFloatingBarSetting) {
        self.session = session
        self.setting = setting
        observe()
    }

    /// Shows or hides the bar now (after the setting changed).
    func update() {
        let shows = MeetingsStatusPolicy.showsFloatingBar(
            MeetingsStatusInput(
                recorderState: session.recorderState, floatingBarEnabled: setting.isEnabled))
        if shows { show() } else { hide() }
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func show() {
        guard panel == nil else { return }
        let origin = movedOrigin ?? Self.defaultOrigin()
        let panel = MeetingsFloatingBarPanel(
            contentRect: NSRect(origin: origin, size: Self.size))
        let content = MeetingsFloatingBarView(session: session)
            .rafuTheme(RafuThemeCatalog.resolvedForCurrentAppearance())
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: Self.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        guard let panel else { return }
        movedOrigin = panel.frame.origin
        panel.orderOut(nil)
        self.panel = nil
    }

    /// The top centre of the main screen, below the menu bar.
    private static func defaultOrigin() -> CGPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        return MeetingsFloatingBarGeometry.origin(visibleFrame: screen.visibleFrame, size: size)
    }
}

/// The pure placement of the floating bar.
nonisolated enum MeetingsFloatingBarGeometry {
    static let size = CGSize(width: 248, height: 40)
    /// The gap under the menu bar.
    static let topGap: CGFloat = 60

    static func origin(visibleFrame: CGRect, size: CGSize) -> CGPoint {
        CGPoint(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: visibleFrame.maxY - topGap - size.height)
    }
}

/// A borderless, non-activating panel on all Spaces, also over a
/// full-screen app. Not in the Window menu and not restored.
final class MeetingsFloatingBarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isRestorable = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        setAccessibilityLabel("Meetings recording bar")
    }
}

/// The content of the floating bar. No title, no name: shape, word, time.
struct MeetingsFloatingBarView: View {
    let session: MeetingsSessionModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let content = MeetingsStatusPolicy.section(
            MeetingsStatusInput(
                recorderState: session.recorderState, elapsed: session.liveElapsed,
                canStartRecording: session.canStartRecording))
        HStack(spacing: RafuMetrics.space2) {
            Image(systemName: content.symbolName)
                .foregroundStyle(
                    content.phase == .recording ? Color.red : theme.palette.textSecondary
                )
                .accessibilityHidden(true)
            Text(content.word)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            if let time = content.timeText {
                Text(time)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Spacer(minLength: RafuMetrics.space2)
            ForEach(content.buttons) { button in
                Button {
                    MeetingsStatusActions.perform(button.action, session: session)
                } label: {
                    Label(button.title, systemImage: button.symbolName)
                }
                .buttonStyle(RafuIconButtonStyle())
                .disabled(!button.isEnabled)
                .help(button.title)
                .accessibilityLabel(button.title)
            }
        }
        .padding(.horizontal, RafuMetrics.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(theme.palette.elevatedBackground))
        .overlay(Capsule().strokeBorder(theme.palette.borderSubtle))
        .contentShape(Capsule())
        .gesture(WindowDragGesture())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meetings recording bar")
    }
}
