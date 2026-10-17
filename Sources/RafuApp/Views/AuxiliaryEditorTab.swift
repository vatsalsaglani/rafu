import SwiftUI

struct AuxiliaryEditorTabContent: View {
    let tab: WorkspaceAuxiliaryTab
    let session: WorkspaceSession

    var body: some View {
        Group {
            switch tab {
            case .settings:
                SettingsCanvas(session: session, showsTabStrip: false)
            case .ensembleStart:
                EnsembleStartCanvas(session: session, showsTabStrip: false)
            case .ensembleNewRun:
                ConductorNewRunCanvas(session: session, showsTabStrip: false)
            case .graph:
                ConductorGraphCanvas(session: session, showsTabStrip: false)
            case .runDetail:
                ConductorRunDetailCanvas(session: session, showsTabStrip: false)
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
