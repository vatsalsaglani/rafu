import Foundation

/// Window-only tabs. They never enter the restorable file/terminal layout.
nonisolated enum WorkspaceAuxiliaryTab: Hashable, Identifiable {
    case settings
    /// A read-only Agent History transcript (X12).
    case agentSession(AgentSessionTabReference)

    var id: Self { self }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .agentSession(let reference): reference.title
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .agentSession: "bubble.left.and.text.bubble.right"
        }
    }
}

extension WorkspaceSession {
    var selectedAuxiliaryTab: WorkspaceAuxiliaryTab? {
        guard selectedDocumentID == nil else { return nil }
        if settingsVisible { return .settings }
        if let reference = agentHistory.visibleSession,
            auxiliaryTabs.contains(.agentSession(reference))
        {
            return .agentSession(reference)
        }
        return nil
    }

    func auxiliaryTabs(in groupID: EditorGroupID) -> [WorkspaceAuxiliaryTab] {
        auxiliaryTabs.filter { auxiliaryTabGroup(for: $0) == groupID }
    }

    func auxiliaryTabGroup(for tab: WorkspaceAuxiliaryTab) -> EditorGroupID {
        if let groupID = auxiliaryTabGroups[tab], editorLayout.group(id: groupID) != nil {
            return groupID
        }
        return editorLayout.focusedGroupID
    }

    func selectedAuxiliaryTab(in groupID: EditorGroupID) -> WorkspaceAuxiliaryTab? {
        guard let tab = selectedAuxiliaryTab, auxiliaryTabGroup(for: tab) == groupID else {
            return nil
        }
        return tab
    }

    /// Called only after a guarded activator succeeds. Opening a canvas does
    /// not remove the selected file, its TextKit resources, or its layout tab.
    func recordAuxiliaryTab(_ tab: WorkspaceAuxiliaryTab) {
        if !auxiliaryTabs.contains(tab) {
            auxiliaryTabs.append(tab)
            auxiliaryTabGroups[tab] = editorLayout.focusedGroupID
        }
        editorLayout.focus(auxiliaryTabGroup(for: tab))
    }

    func selectAuxiliaryTab(_ tab: WorkspaceAuxiliaryTab) {
        guard auxiliaryTabs.contains(tab) else { return }
        prepareAuxiliarySelection()
        suspendAuxiliarySelection()
        switch tab {
        case .settings: settingsVisible = true
        case .agentSession(let reference): agentHistory.visibleSession = reference
        }
        selectedDocumentID = nil
        selectedTreePath = nil
        recordAuxiliaryTab(tab)
    }

    func prepareAuxiliarySelection() {
        closeBlame()
        if gitOpenDiff != nil { closeGitDiff() }
    }

    func suspendAuxiliarySelection() {
        settingsVisible = false
        agentHistory.visibleSession = nil
    }

    func closeAuxiliaryTab(_ tab: WorkspaceAuxiliaryTab) {
        let wasSelected = selectedAuxiliaryTab == tab
        let groupID = auxiliaryTabGroup(for: tab)
        auxiliaryTabs.removeAll { $0 == tab }
        auxiliaryTabGroups[tab] = nil
        guard wasSelected else { return }
        suspendAuxiliarySelection()
        // Return to this group's actual selection. Never choose an unrelated
        // last-opened file, which can move focus into a different split.
        if let tabID = editorLayout.group(id: groupID)?.selectedTabID {
            selectEditorTab(tabID, in: groupID)
        }
    }
}
