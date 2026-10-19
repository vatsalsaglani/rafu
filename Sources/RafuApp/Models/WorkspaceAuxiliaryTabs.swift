import Foundation

/// Window-only tabs. They never enter the restorable file/terminal layout.
nonisolated enum WorkspaceAuxiliaryTab: Hashable, Identifiable {
    case settings
    /// A read-only Agent History transcript (X12).
    case agentSession(AgentSessionTabReference)
    /// The window's one open Git diff. It sits on its group's shelf beside
    /// the file tabs instead of replacing them.
    case gitDiff(GitDiffTabReference)

    var id: Self { self }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .agentSession(let reference): reference.title
        case .gitDiff(let reference): reference.title
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .agentSession: "bubble.left.and.text.bubble.right"
        case .gitDiff: "arrow.left.arrow.right"
        }
    }

    var isGitDiff: Bool {
        if case .gitDiff = self { return true }
        return false
    }
}

/// Names the diff that `WorkspaceSession.gitOpenDiff` holds. Equality is the
/// diff identity ("scope:path"), so a hunk reload keeps the same tab.
nonisolated struct GitDiffTabReference: Hashable, Sendable {
    let identity: String
    let title: String

    init(identity: String, title: String) {
        self.identity = identity
        self.title = title
    }

    init(_ openDiff: GitOpenDiff) {
        self.init(identity: openDiff.id, title: openDiff.title)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

extension WorkspaceSession {
    var selectedAuxiliaryTab: WorkspaceAuxiliaryTab? {
        guard selectedDocumentID == nil else { return nil }
        if settingsVisible { return .settings }
        if isGitDiffSelected, let gitDiffAuxiliaryTab { return gitDiffAuxiliaryTab }
        if let reference = agentHistory.visibleSession,
            auxiliaryTabs.contains(.agentSession(reference))
        {
            return .agentSession(reference)
        }
        return nil
    }

    /// The open diff's tab, when the diff and its tab both exist.
    var gitDiffAuxiliaryTab: WorkspaceAuxiliaryTab? {
        guard let gitOpenDiff else { return nil }
        let tab = WorkspaceAuxiliaryTab.gitDiff(GitDiffTabReference(gitOpenDiff))
        return auxiliaryTabs.contains(tab) ? tab : nil
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
        case .gitDiff: isGitDiffSelected = true
        }
        selectedDocumentID = nil
        selectedTreePath = nil
        recordAuxiliaryTab(tab)
    }

    /// Blame belongs to the selected file, so it closes. An open diff only
    /// hides: `suspendAuxiliarySelection()` keeps its tab on the shelf.
    func prepareAuxiliarySelection() {
        closeBlame()
    }

    func suspendAuxiliarySelection() {
        settingsVisible = false
        agentHistory.visibleSession = nil
        isGitDiffSelected = false
    }

    /// Shows `openDiff` as the window's one diff tab in the focused group.
    /// A different diff replaces the old tab; the same diff keeps its group.
    /// File and terminal tabs stay open and keep their selection.
    func presentGitDiff(_ openDiff: GitOpenDiff) {
        let tab = WorkspaceAuxiliaryTab.gitDiff(GitDiffTabReference(openDiff))
        prepareAuxiliarySelection()
        let replaced = auxiliaryTabs.filter { $0.isGitDiff && $0 != tab }
        auxiliaryTabs.removeAll { replaced.contains($0) }
        for staleTab in replaced { auxiliaryTabGroups[staleTab] = nil }
        gitOpenDiff = openDiff
        suspendAuxiliarySelection()
        isGitDiffSelected = true
        selectedDocumentID = nil
        recordAuxiliaryTab(tab)
    }

    /// Drops every diff tab after `gitOpenDiff` became `nil` by a path that
    /// is not `closeAuxiliaryTab` (blame, a workspace reset), so no tab can
    /// outlive its diff.
    func discardGitDiffAuxiliaryTabs() {
        isGitDiffSelected = false
        guard auxiliaryTabs.contains(where: \.isGitDiff) else { return }
        for tab in auxiliaryTabs where tab.isGitDiff { auxiliaryTabGroups[tab] = nil }
        auxiliaryTabs.removeAll { $0.isGitDiff }
    }

    func closeAuxiliaryTab(_ tab: WorkspaceAuxiliaryTab) {
        let wasSelected = selectedAuxiliaryTab == tab
        let groupID = auxiliaryTabGroup(for: tab)
        auxiliaryTabs.removeAll { $0 == tab }
        auxiliaryTabGroups[tab] = nil
        if tab.isGitDiff, gitOpenDiff != nil {
            MemoryTimeline.shared.note(.diffClosed, source: memoryTimelineSource)
            gitOpenDiff = nil
        }
        guard wasSelected else { return }
        suspendAuxiliarySelection()
        // Return to this group's actual selection. Never choose an unrelated
        // last-opened file, which can move focus into a different split.
        if let tabID = editorLayout.group(id: groupID)?.selectedTabID {
            selectEditorTab(tabID, in: groupID)
        }
    }
}
