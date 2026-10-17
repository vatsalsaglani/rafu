import Foundation

/// Window-only tabs. They never enter the restorable file/terminal layout.
nonisolated enum WorkspaceAuxiliaryTab: Hashable, Identifiable {
    case settings
    case ensembleStart
    case ensembleNewRun
    case graph
    case runDetail(String)

    var id: Self { self }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .ensembleStart: "New Ensemble"
        case .ensembleNewRun: "New Ensemble Run"
        case .graph: "Ensemble"
        case .runDetail: "Ensemble Run"
        }
    }

    var symbol: String {
        self == .settings ? "gearshape" : "person.3"
    }
}

extension WorkspaceSession {
    var selectedAuxiliaryTab: WorkspaceAuxiliaryTab? {
        guard selectedDocumentID == nil else { return nil }
        if settingsVisible { return .settings }
        if ensembleStartCanvasVisible { return .ensembleStart }
        if ensembleNewRunCanvasVisible { return .ensembleNewRun }
        if conductorGraphVisible { return .graph }
        if let conductorRunCanvasID { return .runDetail(conductorRunCanvasID) }
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
        // A window has one run-detail tab. Selecting a different run replaces
        // its detail identity instead of retaining many observing timelines.
        if case .runDetail = tab {
            let oldDetails = auxiliaryTabs.filter {
                if case .runDetail = $0 { return $0 != tab }
                return false
            }
            for old in oldDetails {
                auxiliaryTabs.removeAll { $0 == old }
                auxiliaryTabGroups[old] = nil
            }
        }
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
        case .ensembleStart: ensembleStartCanvasVisible = true
        case .ensembleNewRun: ensembleNewRunCanvasVisible = true
        case .graph: conductorGraphVisible = true
        case .runDetail(let id): conductorRunCanvasID = id
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
        ensembleStartCanvasVisible = false
        ensembleNewRunCanvasVisible = false
        conductorGraphVisible = false
        conductorRunCanvasID = nil
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
