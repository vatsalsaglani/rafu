import AppKit
import Observation
import RafuCore
import SwiftUI

/// Per-card metadata owner. Docking state lives in `CanvasAppDocking`; this
/// object routes the card's explicit actions to it. Creating it starts nothing.
@Observable
final class CanvasNativeAppController {
    let bundleID: String
    let cardID: CanvasCardID
    var status: String?

    init(bundleID: String, cardID: CanvasCardID) {
        self.bundleID = bundleID
        self.cardID = cardID
    }

    var dockState: CanvasDockState { CanvasAppDocking.shared.state(for: cardID) }
    var isDocked: Bool { dockState.isDocked }

    /// Opens or activates the app without docking it.
    func openApp() {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            status = "The app is not installed"
            return
        }
        status = nil
        CanvasAppDocking.launch(bundleID: bundleID)
    }

    /// The explicit Dock action. It may show the system permission prompt once.
    func dock(appName: String, session: WorkspaceSession) {
        status = nil
        let cardID = cardID
        let bundleID = bundleID
        Task {
            await CanvasAppDocking.shared.dock(
                card: cardID, bundleID: bundleID, appName: appName, session: session,
                prompt: true)
        }
    }

    func undock() { CanvasAppDocking.shared.undock(cardID) }

    /// The board hid, paused, or removed this card. Docking re-evaluates: a
    /// removed card gives the window back, a hidden one puts it away.
    func stop() { CanvasAppDocking.shared.refresh(cardID) }
}

struct CanvasNativeAppCard: View {
    @Environment(\.rafuTheme) private var theme
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    @State private var controller: CanvasNativeAppController?
    @State private var visibilityOwner = UUID()
    @State private var appIcon: NSImage?

    private var docking: CanvasAppDocking { .shared }

    var body: some View {
        // A real VStack, not an empty Group, so the lifecycle hooks always run.
        VStack(spacing: 0) {
            if let controller {
                face(controller, state: docking.state(for: card.id))
            } else {
                Text("Preparing app reference…").foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { CanvasDockAnchor(cardID: card.id, owner: visibilityOwner) }
        .onGeometryChange(for: CanvasDockFrames.self) { proxy in
            CanvasDockFrames(
                global: proxy.frame(in: .global),
                board: proxy.frame(in: .named(CanvasConnectionCoordinateSpace.board)))
        } action: { frames in
            docking.updateGeometry(card.id, owner: visibilityOwner, frames: frames)
        }
        .onAppear(perform: appear)
        .onDisappear {
            session.canvasResources[board.id]?.hideNative(card.id, owner: visibilityOwner)
            docking.unmount(card.id, owner: visibilityOwner)
        }
    }

    private func appear() {
        guard let resources = session.canvasResources[board.id],
            resources.board === board
        else { return }
        controller = resources.nativeApp(for: card)
        resources.showNative(card.id, owner: visibilityOwner)
        docking.mount(card.id, owner: visibilityOwner)
        if case .nativeApp(let bundleID) = card.content,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    @ViewBuilder
    private func face(_ controller: CanvasNativeAppController, state: CanvasDockState)
        -> some View
    {
        switch state {
        case .docked:
            dockedFace(controller)
        case .needsPermission:
            permissionFace(controller)
        default:
            referenceFace(controller, state: state)
        }
    }

    private var icon: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon).resizable().scaledToFit()
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit()
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .accessibilityHidden(true)
    }

    private func identity(_ state: CanvasDockState) -> some View {
        VStack(spacing: 4) {
            icon.frame(width: 48, height: 48)
            Text(card.title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary).lineLimit(1)
            Text(state.label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title), \(state.label)")
    }

    /// Not docked, docking, paused, undocked, or failed: the app's identity,
    /// one sentence of state, and the two explicit ways to use it.
    private func referenceFace(_ controller: CanvasNativeAppController, state: CanvasDockState)
        -> some View
    {
        VStack(spacing: 10) {
            identity(state)
            if let detail = controller.status ?? state.detail(appName: card.title) {
                Text(detail).font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state == .docking {
                ProgressView().controlSize(.small)
            } else if state.isDocked {
                Button("Undock") { controller.undock() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Put the \(card.title) window back where it was")
            } else {
                Button("Dock \(card.title)") {
                    controller.dock(appName: card.title, session: session)
                }
                .buttonStyle(RafuProminentButtonStyle())
                .help("Place the real \(card.title) window over this card")
                Button("Open \(card.title)") { controller.openApp() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Open \(card.title) in its own window")
            }
        }
        .padding(12)
    }

    private func permissionFace(_ controller: CanvasNativeAppController) -> some View {
        VStack(spacing: 10) {
            identity(.needsPermission)
            Text(CanvasDockState.needsPermission.detail(appName: card.title) ?? "")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") { docking.openAccessibilitySettings() }
                .buttonStyle(RafuProminentButtonStyle(compact: true))
            Button("Dock \(card.title)") {
                controller.dock(appName: card.title, session: session)
            }
            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            .help("Try again after allowing \(RafuAppIdentity.current.displayName)")
        }
        .padding(12)
    }

    /// The real window sits over this body. When Rafu is in front it covers
    /// the window; a click here brings the app forward again.
    private func dockedFace(_ controller: CanvasNativeAppController) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle, lineWidth: 1)
                .padding(3)
            VStack(spacing: 6) {
                icon.frame(width: 24, height: 24).opacity(0.6)
                Text("Click to show \(card.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.editorBackground.opacity(0.4))
        .contentShape(.rect)
        .onTapGesture {
            board.select([card.id])
            docking.bringForward(card.id)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.title), docked")
        .accessibilityHint("Brings the \(card.title) window forward. Input goes to \(card.title).")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { docking.bringForward(card.id) }
        .accessibilityAction(named: "Undock") { controller.undock() }
    }
}
