import AppKit
import SwiftTerm
import SwiftUI

/// Bottom terminal panel (ADR 0004): tab strip plus the selected SwiftTerm
/// view. Tabs map 1:1 to shell sessions owned by `WorkspaceTerminalManager`.
struct WorkspaceTerminalPanel: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider().overlay(theme.palette.borderSubtle)
            if let selected = session.terminal.selected {
                ZStack {
                    TerminalHostView(controller: selected, theme: theme)
                        .id("\(selected.id)#\(selected.generation)")
                    if !selected.isRunning {
                        shellExitedOverlay(selected)
                    }
                }
            } else {
                emptyState
            }
        }
        .background(theme.palette.editorBackground)
        .task {
            if !session.terminal.hasSessions {
                session.newTerminalTab()
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(session.terminal.sessions) { tab in
                        TerminalTabChip(
                            controller: tab,
                            isSelected: tab.id == session.terminal.selected?.id,
                            select: { session.terminal.selectedID = tab.id },
                            close: { session.terminal.close(tab.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button("New Terminal Tab", systemImage: "plus") {
                session.newTerminalTab()
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
            .help("New Terminal Tab (⌃⇧`)")
            Spacer(minLength: 4)
            if let selected = session.terminal.selected {
                Text(selected.shellDisplayName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.palette.textMuted)
                Button("Restart Shell", systemImage: "arrow.clockwise") {
                    selected.restart()
                }
                .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
                .help("Restart Shell")
            }
            Button("Close Terminal", systemImage: "xmark") {
                session.isTerminalPresented = false
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
            .help("Close Terminal (⌃`)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.palette.tabBarBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No terminal sessions")
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.palette.textSecondary)
            Button("New Terminal Tab", systemImage: "plus") {
                session.newTerminalTab()
            }
            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shellExitedOverlay(_ controller: WorkspaceTerminalController) -> some View {
        VStack(spacing: 10) {
            Text("Shell exited")
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.palette.textSecondary)
            HStack(spacing: 8) {
                Button("Restart Shell", systemImage: "arrow.clockwise") {
                    controller.restart()
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Button("Close Tab", systemImage: "xmark") {
                    session.terminal.close(controller.id)
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.editorBackground.opacity(0.85))
    }
}

private struct TerminalTabChip: View {
    @Bindable var controller: WorkspaceTerminalController
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(controller.isRunning ? theme.palette.success : theme.palette.textMuted)
                .frame(width: 5, height: 5)
                .accessibilityLabel(controller.isRunning ? "Shell running" : "Shell stopped")
            Button(action: select) {
                Text(controller.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected ? theme.palette.textPrimary : theme.palette.textSecondary
                    )
                    .lineLimit(1)
                    .frame(maxWidth: 160)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(controller.currentDirectoryPath ?? controller.startingDirectory)
            Button("Close Tab", systemImage: "xmark", action: close)
                .buttonStyle(RafuIconButtonStyle(size: 15, iconSize: 8))
                .opacity(isHovering || isSelected ? 1 : 0)
                .help("Close \(controller.title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(
                    isSelected
                        ? theme.palette.accentSoft
                        : isHovering ? theme.palette.hover : .clear
                )
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.palette.accent.opacity(isSelected ? 0.5 : 0))
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TerminalHostView: NSViewRepresentable {
    let controller: WorkspaceTerminalController
    let theme: RafuTheme

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = controller.makeOrReuseView(theme: theme)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        controller.applyTheme(theme, to: nsView)
    }
}
