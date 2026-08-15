import AppKit
import SwiftUI

/// Window-centered Ctrl-Tab overlay for editor tabs and terminal sessions.
///
/// The highlighted destination is preview-only. Releasing Control commits it,
/// matching the native macOS application switcher while avoiding repeated
/// document hibernation/persistence work as Left/Right browses the list.
struct EditorTabSwitcherOverlay: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession

    var body: some View {
        if let state = session.editorTabSwitcherState {
            let presentedTerminalIDs = session.presentedTerminalSessionIDs
            ZStack {
                Color.black.opacity(theme.isDark ? 0.20 : 0.08)
                    .contentShape(.rect)

                switcherPanel(state, presentedTerminalIDs: presentedTerminalIDs)
                    .padding(40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func switcherPanel(
        _ state: EditorTabSwitcherState,
        presentedTerminalIDs: Set<UUID>
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: RafuMetrics.space2) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.accent)
                Text("Open Tabs & Terminals")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer()
                RafuChip(text: "⌃Tab")
            }
            .padding(.horizontal, RafuMetrics.space3)
            .frame(height: 38)

            Divider().overlay(theme.palette.borderSubtle)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: RafuMetrics.space2) {
                        ForEach(state.candidates) { candidate in
                            candidateButton(
                                candidate,
                                isSelected: candidate.id == state.selectedCandidate.id,
                                presentedTerminalIDs: presentedTerminalIDs
                            )
                            .id(candidate.id)
                        }
                    }
                    .padding(RafuMetrics.space3)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo(state.selectedCandidate.id, anchor: .center)
                }
                .onChange(of: state.selectedCandidate.id) { _, destination in
                    proxy.scrollTo(destination, anchor: .center)
                }
            }
            .frame(height: 108)

            Divider().overlay(theme.palette.borderSubtle)

            HStack(spacing: RafuMetrics.space3) {
                Text("← → navigate")
                Spacer()
                Text("Release ⌃ to open  ·  Esc cancel")
            }
            .font(.caption2)
            .foregroundStyle(theme.palette.textMuted)
            .padding(.horizontal, RafuMetrics.space3)
            .frame(height: 28)
        }
        .frame(maxWidth: 760)
        .background(theme.palette.elevatedBackground)
        .clipShape(.rect(cornerRadius: RafuMetrics.radiusPanel))
        .overlay {
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderStrong.opacity(0.65))
        }
        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.14), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open tabs and terminals")
        .accessibilityValue(
            presentation(
                for: state.selectedCandidate,
                presentedTerminalIDs: presentedTerminalIDs
            ).title
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                session.moveEditorTabSwitcherSelection(.forward)
            case .decrement:
                session.moveEditorTabSwitcherSelection(.backward)
            @unknown default:
                break
            }
        }
    }

    private func candidateButton(
        _ candidate: EditorTabSwitcherCandidate,
        isSelected: Bool,
        presentedTerminalIDs: Set<UUID>
    ) -> some View {
        let item = presentation(for: candidate, presentedTerminalIDs: presentedTerminalIDs)
        return Button {
            session.commitEditorTabSwitcher(to: candidate.destination)
        } label: {
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                HStack(spacing: RafuMetrics.space2) {
                    candidateIcon(item)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    if item.isDirty {
                        Circle()
                            .fill(theme.palette.accent)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(RafuMetrics.space2)
            .frame(width: 148, height: 82, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(isSelected ? theme.palette.selection : theme.palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.palette.accent : theme.palette.borderSubtle,
                        lineWidth: isSelected ? 2 : RafuMetrics.hairline
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func candidateIcon(_ item: Presentation) -> some View {
        if let fileIcon = item.fileIcon {
            FileIconView(icon: fileIcon, size: 16)
        } else {
            Image(systemName: item.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.palette.accent)
        }
    }

    private func presentation(
        for candidate: EditorTabSwitcherCandidate,
        presentedTerminalIDs: Set<UUID>
    ) -> Presentation {
        switch candidate.destination {
        case .editorTab(let tabID, let groupID):
            guard
                let tab = session.editorLayout.group(id: groupID)?.tabs.first(where: {
                    $0.id == tabID
                })
            else {
                return Presentation(
                    title: "Unavailable Tab",
                    detail: "No longer open",
                    symbolName: "questionmark.square.dashed"
                )
            }
            switch tab.resource {
            case .file(let url):
                let document = session.document(for: tab)
                let title = document?.displayName ?? url.lastPathComponent
                return Presentation(
                    title: title,
                    detail: editorDetail(
                        groupID: groupID,
                        suffix: url.deletingLastPathComponent()
                            .lastPathComponent),
                    fileIcon: FileIconProvider.fileIcon(named: title),
                    symbolName: "doc.text",
                    isDirty: document?.isDirty == true
                )
            case .restorable(_, _, let title):
                return Presentation(
                    title: title,
                    detail: editorDetail(groupID: groupID, suffix: "Restorable item"),
                    symbolName: "rectangle.on.rectangle"
                )
            case .terminal:
                return Presentation(
                    title: "Terminal",
                    detail: editorDetail(groupID: groupID, suffix: "Terminal"),
                    symbolName: "terminal"
                )
            case .terminalGroup:
                return Presentation(
                    title: "Terminal Group",
                    detail: editorDetail(groupID: groupID, suffix: "Terminal Group"),
                    symbolName: "rectangle.3.group"
                )
            }

        case .terminal(let sessionID):
            guard let controller = session.terminal.sessions.first(where: { $0.id == sessionID })
            else {
                return Presentation(
                    title: "Unavailable Terminal",
                    detail: "Session closed",
                    symbolName: "terminal"
                )
            }
            let isPresented = presentedTerminalIDs.contains(sessionID)
            return Presentation(
                title: controller.displayName,
                detail: terminalDetail(controller.status, isPresented: isPresented),
                fileIcon: EditorTabSwitcherAgentIdentity.icon(for: controller.agentProvider),
                symbolName: terminalSymbol(controller.status)
            )

        case .terminalGroup:
            // TG-10 adds destination identity only. No current candidate can
            // produce this branch; TG-40 owns final group presentation.
            return Presentation(
                title: "Terminal Group",
                detail: "Unavailable",
                symbolName: "rectangle.3.group"
            )
        }
    }

    private func editorDetail(groupID: EditorGroupID, suffix: String) -> String {
        let index =
            session.editorLayout.groupIDs.firstIndex(of: groupID)
            .map { $0 + 1 } ?? 1
        return "Editor \(index)  ·  \(suffix)"
    }

    private func terminalDetail(_ status: TerminalSessionStatus, isPresented: Bool) -> String {
        let placement = isPresented ? "Terminal" : "Hidden terminal"
        switch status {
        case .idle:
            return "\(placement)  ·  Not started"
        case .running:
            return "\(placement)  ·  Running"
        case .bell:
            return "\(placement)  ·  Needs attention"
        case .exited(let code):
            return code.map { "\(placement)  ·  Exited \($0)" }
                ?? "\(placement)  ·  Exited"
        }
    }

    private func terminalSymbol(_ status: TerminalSessionStatus) -> String {
        switch status {
        case .bell: "bell.badge"
        case .exited: "terminal.fill"
        case .idle, .running: "terminal"
        }
    }

    private struct Presentation {
        let title: String
        let detail: String
        var fileIcon: FileIconProvider.Icon?
        let symbolName: String
        var isDirty = false
    }
}

nonisolated enum EditorTabSwitcherAgentIdentity {
    static func icon(for provider: ConductorCLIID?) -> FileIconProvider.Icon? {
        provider.map(ConductorCLIIcons.icon(for:))
    }
}

/// The smallest AppKit boundary needed by the switcher: SwiftUI menu commands
/// reliably receive Ctrl-Tab even when TextKit/SwiftTerm owns first responder,
/// but SwiftUI has no window-scoped modifier-release hook. This zero-sized
/// representable listens only while its own window is key and only consumes
/// Left, Right, Escape, and Return while the switcher is visible.
struct EditorTabSwitcherEventBridge: NSViewRepresentable {
    let isPresented: () -> Bool
    let move: (EditorTabSwitcherDirection) -> Void
    let commit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(context.coordinator)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(context.coordinator)
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func configure(_ coordinator: Coordinator) {
        coordinator.isPresented = isPresented
        coordinator.move = move
        coordinator.commit = commit
        coordinator.cancel = cancel
    }

    @MainActor
    final class Coordinator: NSObject {
        var isPresented: () -> Bool = { false }
        var move: (EditorTabSwitcherDirection) -> Void = { _ in }
        var commit: () -> Void = {}
        var cancel: () -> Void = {}

        private weak var window: NSWindow?
        private var eventMonitor: Any?

        isolated deinit {
            NotificationCenter.default.removeObserver(self)
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                self.bind(to: window)
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            window = nil
        }

        private func bind(to window: NSWindow) {
            guard self.window !== window || eventMonitor == nil else { return }
            detach()
            self.window = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .flagsChanged]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            if isPresented() {
                cancel()
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, window.isKeyWindow,
                event.window == nil || event.window === window,
                isPresented()
            else { return event }

            if event.type == .flagsChanged {
                if !event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .contains(.control)
                {
                    commit()
                }
                return event
            }

            switch event.keyCode {
            case 123:  // Left Arrow
                move(.backward)
                return nil
            case 124:  // Right Arrow
                move(.forward)
                return nil
            case 53:  // Escape
                cancel()
                return nil
            case 36, 76:  // Return / Keypad Enter
                commit()
                return nil
            default:
                // Ctrl-Tab itself continues to the SwiftUI menu key
                // equivalent, which advances the same model. Every other
                // key retains normal first-responder behavior.
                return event
            }
        }
    }
}
