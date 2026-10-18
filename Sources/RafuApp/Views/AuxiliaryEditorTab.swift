import SwiftUI

struct AuxiliaryEditorTabContent: View {
    let tab: WorkspaceAuxiliaryTab
    let session: WorkspaceSession

    var body: some View {
        Group {
            switch tab {
            case .settings:
                SettingsCanvas(session: session, showsTabStrip: false)
            case .agentSession(let reference):
                AgentSessionTabView(
                    reference: reference,
                    model: session.agentHistory.transcripts[reference.key],
                    session: session,
                    isActive: session.selectedAuxiliaryTab == tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct AuxiliaryEditorTabItem: View {
    @State private var isHovering = false
    let tab: WorkspaceAuxiliaryTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        AttachedWorkbenchTab(isSelected: isSelected, usesDocumentWidth: true) {
            HStack(spacing: 6) {
                Button(action: select) {
                    Label(tab.title, systemImage: tab.symbol)
                        .lineLimit(1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close \(tab.title)",
                    help: "Close \(tab.title)",
                    action: close
                )
                .opacity(isHovering || isSelected ? 1 : 0)
            }
        }
        .onHover { isHovering = $0 }
        .help(tab.title)
        .accessibilityElement(children: .contain)
    }
}
