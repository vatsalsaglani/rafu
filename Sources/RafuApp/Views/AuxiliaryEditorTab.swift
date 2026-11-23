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
                AgentSessionPane(
                    reference: reference,
                    model: session.agentHistory.transcripts[reference.key],
                    session: session,
                    isActive: session.selectedAuxiliaryTab == tab)
            case .gitDiff:
                if let openDiff = session.gitOpenDiff {
                    GitSideBySideDiffView(openDiff: openDiff, session: session)
                }
            case .meeting(let meeting):
                MeetingsTabHost(session: session, meeting: meeting)
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
        let title = tab.displayTitle
        AttachedWorkbenchTab(isSelected: isSelected, usesDocumentWidth: true, select: select) {
            HStack(spacing: 6) {
                Label(title, systemImage: tab.symbol)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .workbenchTabLabel(
                        title, value: isSelected ? "Selected" : "", isSelected: isSelected,
                        select: select)
                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close \(title)",
                    help: "Close \(title)",
                    action: close
                )
                .opacity(isHovering || isSelected ? 1 : 0)
            }
        }
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityElement(children: .contain)
    }
}
