import SwiftUI

/// Shared sizes for the Source Control panel (G2).
private enum GitPanelMetrics {
    /// One-line file row height.
    static let fileRowHeight: CGFloat = 24
    /// Side of the rounded status-letter square.
    static let statusBadgeSize: CGFloat = 16
}

struct SourceControlPanelView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    @State private var isCreatingBranch = false
    @State private var newBranchName = ""
    @State private var pendingMergeBranch: String?

    var body: some View {
        VStack(spacing: 0) {
            RafuUtilityPanelHeader(
                icon: WorkspaceNavigatorMode.sourceControl.symbolName,
                title: "Source Control",
                closeAccessibilityLabel: "Close Source Control",
                onClose: { session.isSidebarCollapsed = true }
            ) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refreshAllGitState() }
                    session.refreshAllGitRepositories()
                }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .help("Refresh Source Control")
            }

            SourceControlRepositoriesSection(session: session)

            if session.gitSnapshot != nil {
                repositoryContext
                GitInspectorView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                RafuPanelEmptyState(
                    icon: "arrow.triangle.branch",
                    title: "No Git Repository",
                    message: "Initialize Git in this workspace to use Source Control."
                ) {
                    // Explicit user action — Rafu never initializes a
                    // repository on its own (AGENTS: Git stays explicit).
                    Button("Initialize Repository") {
                        Task { await session.gitInitializeRepository() }
                    }
                    .buttonStyle(RafuProminentButtonStyle())
                    .disabled(session.descriptor == nil || session.isGitBusy)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert("Create Branch", isPresented: $isCreatingBranch) {
            TextField("Branch name", text: $newBranchName)
            Button("Cancel", role: .cancel) { newBranchName = "" }
            Button("Create and Check Out") {
                let name = newBranchName
                newBranchName = ""
                Task { await session.gitCreateBranch(named: name) }
            }
            .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Create a branch from the current HEAD and switch to it.")
        }
        .confirmationDialog(
            "Merge \(pendingMergeBranch ?? "branch") into \(snapshot.branch)?",
            isPresented: mergeConfirmationBinding
        ) {
            if let branch = pendingMergeBranch {
                Button("Merge \(branch)") {
                    pendingMergeBranch = nil
                    Task { await session.gitMergeBranch(named: branch) }
                }
            }
            Button("Cancel", role: .cancel) { pendingMergeBranch = nil }
        } message: {
            Text("Git may stop for conflicts. Rafu will show conflicted files in Changes.")
        }
    }

    private var repositoryContext: some View {
        HStack(spacing: RafuMetrics.space2) {
            branchMenu
            Spacer(minLength: RafuMetrics.space1)
            syncMenu
        }
        .padding(.horizontal, RafuMetrics.utilityBodyInset)
        .padding(.vertical, RafuMetrics.space2)
        .background(theme.palette.elevatedBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: RafuMetrics.hairline)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    /// One branch pull-down (G4, G13): Switch To, Create Branch…, Merge into
    /// Current. Rename and Delete are omitted because `GitService` has no
    /// primitive for them. Searchable switching stays in the status bar.
    @ViewBuilder
    private var branchMenu: some View {
        if let branches = session.gitBranchSnapshot {
            Menu {
                Menu("Switch To", systemImage: "arrow.triangle.swap") {
                    ForEach(branches.localBranches) { branch in
                        Button {
                            guard !branch.isCurrent else { return }
                            Task { await session.gitCheckoutBranch(named: branch.name) }
                        } label: {
                            if branch.isCurrent {
                                Label(branch.name, systemImage: "checkmark")
                            } else {
                                Text(branch.name)
                            }
                        }
                        .disabled(branch.isCurrent)
                    }
                    if !branches.remoteBranches.isEmpty {
                        Divider()
                        Menu("Remote Branches") {
                            ForEach(branches.remoteBranches) { branch in
                                Button(branch.name) {
                                    Task { await session.gitCheckoutBranch(named: branch.name) }
                                }
                            }
                        }
                    }
                }
                .disabled(branches.localBranches.count < 2 && branches.remoteBranches.isEmpty)
                Button("Create Branch…", systemImage: "plus") { isCreatingBranch = true }
                Menu("Merge into Current", systemImage: "arrow.triangle.merge") {
                    ForEach(branches.localBranches.filter { !$0.isCurrent }) { branch in
                        Button(branch.name) { pendingMergeBranch = branch.name }
                    }
                }
                .disabled(branches.localBranches.allSatisfy(\.isCurrent))
            } label: {
                branchMenuLabel
            }
            .menuStyle(.borderlessButton)
            .tint(theme.palette.textSecondary)
            .menuIndicator(.hidden)
            .help("Switch, create, or merge branches — \(snapshot.branch)")
            .accessibilityLabel("Branch \(snapshot.branch)")
        } else {
            branchMenuLabel
                .foregroundStyle(theme.palette.textMuted)
                .help(snapshot.branch)
        }
    }

    private var branchMenuLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .medium))
            Text(snapshot.branch)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(theme.palette.textPrimary)
        .contentShape(.rect)
    }

    private var syncPresentation: GitSyncPresentation {
        GitSyncPresentation.resolve(
            hasRemote: !session.gitRemoteNames.isEmpty
                || session.gitBranchSnapshot?.upstream != nil,
            upstream: session.gitBranchSnapshot?.upstream,
            aheadCount: session.gitBranchSnapshot?.aheadCount ?? 0,
            behindCount: session.gitBranchSnapshot?.behindCount ?? 0
        )
    }

    /// One neutral sync control (G4, G15): a capsule with "↑n ↓n" when the
    /// branch tracks an upstream, "No remote" when there is no remote. Fetch,
    /// Pull, and Push are disabled without a remote.
    private var syncMenu: some View {
        let presentation = syncPresentation
        let disabledHelp = presentation.canSync ? nil : GitSyncPresentation.noRemoteHelp
        return Menu {
            Button("Fetch All", systemImage: "arrow.clockwise") {
                Task { await session.gitFetch() }
            }
            .disabled(!presentation.canSync)
            .help(disabledHelp ?? "Fetch from every remote")
            Menu("Pull", systemImage: "arrow.down.circle") {
                Button("Merge") { Task { await session.gitPull(strategy: .merge) } }
                Button("Rebase") { Task { await session.gitPull(strategy: .rebase) } }
                Button("Fast-Forward Only") {
                    Task { await session.gitPull(strategy: .fastForwardOnly) }
                }
            }
            .disabled(!presentation.canSync)
            .help(disabledHelp ?? "Pull from the upstream branch")
            pushItem(disabledHelp: disabledHelp)
            if !presentation.canSync, session.canPublishToGitHub {
                // A generic "Add Remote…" has no GitService primitive. The
                // GitHub publish flow is the one existing path that adds an
                // `origin` remote, and it stays an explicit user action.
                Divider()
                Button("Publish to GitHub…", systemImage: "arrow.up.forward.app") {
                    session.isGitHubPublishPresented = true
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .medium))
                Text(presentation.label)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.palette.chipBackground))
            .contentShape(.capsule)
        }
        .menuStyle(.borderlessButton)
        .tint(theme.palette.textSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(disabledHelp ?? syncHelp)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var syncHelp: String {
        guard let upstream = session.gitBranchSnapshot?.upstream else {
            return "Fetch, pull, or push"
        }
        return "Fetch, pull, or push — tracking \(upstream)"
    }

    @ViewBuilder
    private func pushItem(disabledHelp: String?) -> some View {
        if session.gitBranchSnapshot?.upstream != nil {
            Button("Push", systemImage: "arrow.up.circle") {
                Task { await session.gitPush() }
            }
        } else if !session.gitRemoteNames.isEmpty {
            Menu("Publish Branch", systemImage: "arrow.up.circle") {
                ForEach(session.gitRemoteNames, id: \.self) { remote in
                    Button(remote) { Task { await session.gitPush(remote: remote) } }
                }
            }
        } else {
            Button("Push", systemImage: "arrow.up.circle") {
                Task { await session.gitPush() }
            }
            .disabled(true)
            .help(disabledHelp ?? "Push the current branch")
        }
    }

    private var snapshot: GitSnapshot {
        session.gitSnapshot ?? GitSnapshot(branch: "Git", changes: [])
    }

    private var mergeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingMergeBranch != nil },
            set: { if !$0 { pendingMergeBranch = nil } }
        )
    }

    private func refreshAllGitState() async {
        await session.refreshGit()
        await GitStashCoordinator.refresh(session: session)
    }
}

struct GitInspectorView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    @State private var isStashSheetPresented = false
    @State private var isStashesExpanded = true
    @State private var isAddWorktreeSheetPresented = false
    @State private var pendingStashAction: PendingStashAction?
    @State private var pendingWorktreeRemoval: GitWorktree?
    /// Whether the commit composer's hygiene-warning row is expanded to
    /// list the flagged paths. Local, ephemeral UI state — never persisted.
    @State private var isHygieneWarningExpanded = false
    @FocusState private var isCommitMessageFocused: Bool
    @AppStorage("gitChangesViewMode") private var gitChangesViewModeRaw =
        GitChangesViewMode.flat.rawValue

    private var changesViewMode: GitChangesViewMode {
        GitChangesViewMode(rawValue: gitChangesViewModeRaw) ?? .flat
    }

    var body: some View {
        VStack(spacing: 0) {
            if let mergeState = session.gitMergeState {
                mergeBanner(mergeState)
            }
            GitSectionPicker(
                items: GitInspectorSection.allCases,
                selection: $session.gitInspectorSection,
                changeCount: snapshot.changes.count
            )
            .accessibilityLabel("Source Control section")
            .accessibilityValue(session.gitInspectorSection.title)
            .padding(.horizontal, RafuMetrics.utilityBodyInset)
            .padding(.vertical, RafuMetrics.space2)
            .frame(maxWidth: .infinity, alignment: .leading)

            switch session.gitInspectorSection {
            case .changes:
                changesView
            case .worktrees:
                worktreesView
            case .history:
                historyView
            }
        }
        .frame(minWidth: 300, idealWidth: 340)
        // `alignment: .top` is load-bearing: `.frame(maxHeight: .infinity)`
        // defaults to CENTER alignment, so any tab whose content under-fills
        // (History with no commits) floated the whole header/picker stack to
        // the vertical middle of the panel. Header and tabs must stay pinned
        // to the top regardless of how empty the selected tab is (AGENTS:
        // panel/tab containers pin to the top).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if session.isGitBusy {
                ProgressView().controlSize(.small).padding(10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
            }
        }
        .task(id: session.gitRootURL) { await refreshAllGitState() }
        .confirmationDialog(
            pendingStashAction?.title ?? "Update stash?",
            isPresented: stashConfirmationBinding
        ) {
            if let action = pendingStashAction {
                Button(action.confirmationLabel, role: .destructive) {
                    pendingStashAction = nil
                    Task {
                        switch action {
                        case .pop(let entry): await session.popStash(entry)
                        case .drop(let entry): await session.dropStash(entry)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingStashAction = nil }
        } message: {
            Text(pendingStashAction?.message ?? "The stash list will remain unchanged.")
        }
        .sheet(isPresented: $isStashSheetPresented) {
            GitStashChangesSheet(session: session)
        }
    }

    private func mergeBanner(_ mergeState: GitMergeState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.info)
            VStack(alignment: .leading, spacing: 1) {
                Text("Merge in progress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(mergeState.headline)
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(theme.palette.info.opacity(0.10))
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Merge in progress: \(mergeState.headline)")
    }

    private var changesView: some View {
        VStack(spacing: 0) {
            changesHeader
            if snapshot.changes.isEmpty && session.gitStashes.isEmpty {
                // Expand so the commit composer pins to the panel bottom
                // instead of floating mid-panel with dead space beneath.
                RafuPanelEmptyState(
                    icon: "checkmark.circle",
                    title: "No Changes",
                    message: "Your working tree is clean."
                )
            } else {
                List(selection: $session.gitSelectedChangeIDs) {
                    if !snapshot.conflicts.isEmpty {
                        Section("Conflicts (\(snapshot.conflicts.count))") {
                            ForEach(snapshot.conflicts) { change in
                                changeRow(change, scope: .workingTree)
                            }
                        }
                    }
                    switch changesViewMode {
                    case .flat:
                        if !snapshot.stagedChanges.isEmpty {
                            Section("Staged (\(snapshot.stagedChanges.count))") {
                                ForEach(snapshot.stagedChanges) { change in
                                    changeRow(change, scope: .staged)
                                }
                            }
                        }
                        if !snapshot.unstagedChanges.isEmpty {
                            Section("Changes (\(snapshot.unstagedChanges.count))") {
                                ForEach(snapshot.unstagedChanges) { change in
                                    changeRow(change, scope: .workingTree)
                                }
                            }
                        }
                    case .tree:
                        let nonConflictedChanges = snapshot.changes.filter { !$0.isConflicted }
                        if !nonConflictedChanges.isEmpty {
                            Section("Changes (\(nonConflictedChanges.count))") {
                                GitChangeTreeRows(session: session, changes: nonConflictedChanges)
                            }
                        }
                    }
                    if !session.gitStashes.isEmpty {
                        stashSection
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, GitPanelMetrics.fileRowHeight)
            }
            commitComposer
        }
    }

    /// Count on the left; a neutral "View as" pull-down and a neutral stash
    /// icon on the right (G5). Nothing here is gold.
    private var changesHeader: some View {
        HStack(spacing: 6) {
            Text(
                "\(snapshot.changes.count) changed \(snapshot.changes.count == 1 ? "file" : "files")"
            )
            .font(.system(size: 12))
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            Spacer(minLength: 4)
            Button("Stash Changes…", systemImage: "archivebox") {
                isStashSheetPresented = true
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 11))
            .disabled(snapshot.changes.isEmpty || session.isGitBusy || session.isGitHunkActionBusy)
            .help("Stash Changes…")
            viewAsMenu
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var viewAsMenu: some View {
        Menu {
            Picker("View as", selection: changesViewModeBinding) {
                ForEach(GitChangesViewMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text("View as")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(theme.palette.textSecondary)
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .tint(theme.palette.textSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("View as List or Tree")
        .accessibilityLabel("View as")
        .accessibilityValue(changesViewMode.title)
    }

    private var changesViewModeBinding: Binding<GitChangesViewMode> {
        Binding(
            get: { changesViewMode },
            set: { gitChangesViewModeRaw = $0.rawValue }
        )
    }

    private var stashSection: some View {
        Section {
            if isStashesExpanded {
                ForEach(session.gitStashes) { entry in
                    GitStashRow(
                        entry: entry,
                        apply: { Task { await session.applyStash(entry) } },
                        requestPop: { pendingStashAction = .pop(entry) },
                        requestDrop: { pendingStashAction = .drop(entry) }
                    )
                }
            }
        } header: {
            Button {
                isStashesExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isStashesExpanded ? 90 : 0))
                    Label("Stashes (\(session.gitStashes.count))", systemImage: "archivebox")
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(isStashesExpanded ? "Collapse" : "Expand") stashes, \(session.gitStashes.count) entries"
            )
        }
    }

    private var worktreesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label(
                    "Worktrees (\(session.gitWorktrees.count))",
                    systemImage: "point.3.filled.connected.trianglepath.dotted"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                Spacer()
                Button("Add Worktree", systemImage: "plus") {
                    isAddWorktreeSheetPresented = true
                }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .help("Add a worktree")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await session.loadWorktrees() }
                }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .help("Refresh worktrees")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            if session.gitWorktrees.isEmpty {
                ContentUnavailableView(
                    "No Worktrees",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(
                        "Add a worktree to run a branch — or an agent lane — in parallel.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(session.gitWorktrees) { worktree in
                        GitWorktreeRow(
                            worktree: worktree,
                            isCurrent: worktree.path == session.currentWorktreePath,
                            openInNewWindow: { session.openWorktreeInNewWindow(worktree) },
                            remove: worktree.isMain ? nil : { pendingWorktreeRemoval = worktree }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, 4)
        .task(id: session.gitRootURL) { await session.loadWorktrees() }
        .sheet(isPresented: $isAddWorktreeSheetPresented) {
            GitAddWorktreeSheet(session: session)
        }
        .confirmationDialog(
            "Remove worktree “\(pendingWorktreeRemoval?.name ?? "")”?",
            isPresented: worktreeRemovalBinding
        ) {
            if let worktree = pendingWorktreeRemoval {
                Button("Remove Worktree", role: .destructive) {
                    pendingWorktreeRemoval = nil
                    Task { await session.removeWorktree(worktree) }
                }
            }
            Button("Cancel", role: .cancel) { pendingWorktreeRemoval = nil }
        } message: {
            Text(
                "The worktree's files are removed from disk. Git refuses if it has uncommitted changes or is locked; its branch is not deleted."
            )
        }
    }

    private var worktreeRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingWorktreeRemoval != nil },
            set: { if !$0 { pendingWorktreeRemoval = nil } }
        )
    }

    private func changeRow(_ change: GitChange, scope: GitDiffScope) -> some View {
        GitChangeRow(
            change: change,
            presentation: scope == .staged ? .staged : .unstaged,
            toggleStaged: {
                Task { await session.setStaged(scope != .staged, change: change) }
            }
        )
        .tag(change.id)
        .contentShape(.rect)
        .onTapGesture {
            Task { await session.gitOpenChangeDiff(change, scope: scope) }
        }
        .contextMenu {
            Button(
                scope == .staged ? "Open Staged Diff" : "Open Working Tree Diff",
                systemImage: "arrow.left.arrow.right"
            ) {
                Task { await session.gitOpenChangeDiff(change, scope: scope) }
            }
            Divider()
            Button(
                scope == .staged ? "Unstage" : "Stage",
                systemImage: scope == .staged ? "minus.circle" : "plus.circle"
            ) {
                Task { await session.setStaged(scope != .staged, change: change) }
            }
        }
    }

    /// Message field with the AI draft control inside its trailing edge (G7),
    /// a "Commits N files" caption, and Commit as the panel's one accent
    /// button. ⌘Return commits while the field has focus.
    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            commitMessageField
            if let error = session.aiCommitGenerationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.error)
            }
            if !session.commitHygieneFindings.isEmpty {
                commitHygieneWarning(session.commitHygieneFindings)
            }
            HStack(spacing: 8) {
                Text(GitCommitCaption.text(stagedCount: snapshot.stagedChanges.count))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Stage All") { Task { await session.stageAll() } }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Button("Commit") { Task { await session.commit() } }
                    .buttonStyle(RafuProminentButtonStyle(compact: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Commit staged changes (⌘Return)")
                    .disabled(
                        session.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty || snapshot.stagedChanges.isEmpty
                            || session.isGeneratingAICommitMessage
                    )
            }
        }
        .padding(10)
        .background(theme.palette.cardBackground)
        .clipShape(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
        )
        .aiCommitGeneratingBorder(isActive: session.isGeneratingAICommitMessage)
        .padding(RafuMetrics.utilityBodyInset)
    }

    private var commitMessageField: some View {
        TextField("Message", text: $session.gitCommitMessage, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .focused($isCommitMessageFocused)
            .padding(.trailing, 24)
            .rafuField(isFocused: isCommitMessageFocused)
            .overlay(alignment: .topTrailing) {
                draftControl
                    .padding(.top, 2)
                    .padding(.trailing, 2)
            }
    }

    @ViewBuilder
    private var draftControl: some View {
        if session.isGeneratingAICommitMessage {
            HStack(spacing: 2) {
                ProgressView().controlSize(.mini)
                Button("Stop Generating", systemImage: "stop.fill") {
                    session.cancelAICommitGeneration()
                }
                .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
                .help("Stop generating the commit message.")
            }
        } else {
            Button("Draft Message with AI", systemImage: "sparkles") {
                session.startAICommitGeneration()
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 12))
            .keyboardShortcut("g", modifiers: [.command, .option])
            .disabled(!session.canGenerateAICommitMessage)
            .help(
                "Draft Message with AI (⌥⌘G). From \(session.aiCommitGenerationScopeDescription). No commit is created automatically."
            )
        }
    }

    /// Calm, advisory-only warning for `CommitHygieneChecker.findings` on the
    /// staged changeset. Never disables Commit — only informs, with an
    /// optional expansion listing each flagged path, its reason, and a
    /// per-row Unstage shortcut. No decorative animation.
    private func commitHygieneWarning(_ findings: [CommitHygieneFinding]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isHygieneWarningExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Label(
                        "\(findings.count) staged \(findings.count == 1 ? "file" : "files") may not belong in a commit",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(theme.palette.warning)
                    Spacer()
                    Image(systemName: isHygieneWarningExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(findings.count) staged files may not belong in a commit. Toggle details.")

            if isHygieneWarningExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(findings) { finding in
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.path)
                                    .font(.caption2)
                                    .foregroundStyle(theme.palette.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(finding.reason)
                                    .font(.caption2)
                                    .foregroundStyle(theme.palette.textSecondary)
                            }
                            Spacer(minLength: 4)
                            Button("Unstage") {
                                guard
                                    let change = snapshot.stagedChanges.first(where: {
                                        $0.path == finding.path
                                    })
                                else { return }
                                Task { await session.setStaged(false, change: change) }
                            }
                            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(
            theme.palette.warning.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    private var historyView: some View {
        VStack(spacing: 0) {
            if let commits = session.gitHistoryPage?.commits, !commits.isEmpty {
                // GX3: the commit-graph lane/chip row replaces the plain
                // commit-row list, but keeps the SAME
                // `gitSelectedHistoryCommitID` selection binding and the
                // same `gitSelectHistoryCommit` tap handler every other
                // History entry point already uses. G11: the selected
                // commit's details expand directly under its row.
                GitCommitGraphView(
                    commits: commits,
                    upstream: session.gitBranchSnapshot?.upstream,
                    lastFetchedAt: session.gitLastFetchedAt,
                    hasMore: session.gitHistoryPage?.hasMore ?? false,
                    isBusy: session.isGitBusy,
                    rootURL: session.gitRootURL,
                    headOID: session.gitSnapshot?.headOID,
                    selection: $session.gitSelectedHistoryCommitID,
                    detailChanges: session.gitHistoryCommitChanges,
                    isDetailLoading: session.isGitHistoryDetailLoading,
                    onSelect: { commit in Task { await session.gitSelectHistoryCommit(commit) } },
                    onOpenDiff: { change in Task { await session.gitOpenHistoryDiff(change) } },
                    onFetch: { Task { await session.gitFetch() } },
                    onLoadMore: { Task { await session.loadMoreHistory() } }
                )
            } else {
                // Expands to claim the tab's remaining space so the empty
                // state centers WITHIN it — without this the under-filled
                // panel used to center the header and tab picker themselves.
                ContentUnavailableView(
                    "No commits yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Commit history will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var snapshot: GitSnapshot {
        session.gitSnapshot ?? GitSnapshot(branch: "Git", changes: [])
    }

    private var stashConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingStashAction != nil },
            set: { if !$0 { pendingStashAction = nil } }
        )
    }

    private func refreshAllGitState() async {
        await session.refreshGit()
        await GitStashCoordinator.refresh(session: session)
    }
}

/// "Changes (n) | History | Worktrees" (G1). Words never wrap: every segment
/// is one line with a fixed (equal) width, and below
/// `GitSectionPickerLayout.iconThreshold` the segments show icons with
/// tooltips instead.
private struct GitSectionPicker: View {
    @Environment(\.rafuTheme) private var theme
    let items: [GitInspectorSection]
    @Binding var selection: GitInspectorSection
    let changeCount: Int

    var body: some View {
        GeometryReader { proxy in
            let usesIcons = GitSectionPickerLayout.usesIcons(forWidth: proxy.size.width)
            HStack(spacing: 2) {
                ForEach(items, id: \.self) { item in
                    segment(for: item, usesIcons: usesIcons)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.palette.appBackground.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(theme.palette.borderSubtle)
            )
        }
        .frame(height: 28)
    }

    private func segment(for item: GitInspectorSection, usesIcons: Bool) -> some View {
        let isSelected = item == selection
        let label = item.segmentLabel(changeCount: changeCount)
        return Button {
            selection = item
        } label: {
            Group {
                if usesIcons {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                } else {
                    Text(label)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(isSelected ? theme.palette.textPrimary : theme.palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(theme.palette.elevatedBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .strokeBorder(theme.palette.borderStrong.opacity(0.6))
                        )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum PendingStashAction: Identifiable {
    case pop(GitStashEntry)
    case drop(GitStashEntry)

    var id: String {
        switch self {
        case .pop(let entry): "pop:\(entry.selector)"
        case .drop(let entry): "drop:\(entry.selector)"
        }
    }

    var title: String {
        switch self {
        case .pop: "Pop this stash?"
        case .drop: "Drop this stash?"
        }
    }

    var confirmationLabel: String {
        switch self {
        case .pop: "Pop and Remove Stash"
        case .drop: "Drop Stash"
        }
    }

    var message: String {
        switch self {
        case .pop:
            "Git will apply these changes and remove the stash only if the apply succeeds. Conflicts may require manual resolution."
        case .drop:
            "This permanently removes the stash reference. The stashed changes will not be applied."
        }
    }
}

private struct GitStashChangesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkspaceSession
    @State private var includeUntracked = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "archivebox",
                title: "Stash Changes",
                subtitle:
                    "Save the current working tree explicitly. Rafu never stashes automatically."
            )

            Form {
                TextField("Message (Optional)", text: $message, axis: .vertical)
                    .lineLimit(2...4)
                Toggle("Include untracked files", isOn: $includeUntracked)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stash Changes") {
                    let submittedMessage = message
                    let submittedIncludeUntracked = includeUntracked
                    Task {
                        await session.stashChanges(
                            message: submittedMessage,
                            includeUntracked: submittedIncludeUntracked
                        )
                        dismiss()
                    }
                }
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(session.gitSnapshot?.changes.isEmpty != false || session.isGitBusy)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 440)
    }
}

/// One-line stash row (G6): archive glyph, name, relative date. The "···"
/// menu replaces the date while the pointer is over the row; the same items
/// are always in the context menu. Branch and selector live in the tooltip.
private struct GitStashRow: View {
    let entry: GitStashEntry
    let apply: () -> Void
    let requestPop: () -> Void
    let requestDrop: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(entry.message)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(theme.palette.textPrimary)
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                Text(GitRelativeTime.label(for: entry.createdAt))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .opacity(isHovering ? 0 : 1)
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(width: 24, height: 20)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .tint(theme.palette.textSecondary)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Stash Actions")
                .accessibilityLabel("Stash Actions")
                .opacity(isHovering ? 1 : 0)
            }
            .fixedSize()
        }
        .frame(minHeight: GitPanelMetrics.fileRowHeight)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .animation(isHovering ? RafuMotion.hoverIn : RafuMotion.hoverOut, value: isHovering)
        .contextMenu { actions }
        .help(helpText)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Apply Stash", systemImage: "arrow.down.doc") { apply() }
        Button("Pop Stash…", systemImage: "arrow.down.doc.fill") { requestPop() }
        Divider()
        Button("Drop Stash…", systemImage: "trash", role: .destructive) { requestDrop() }
    }

    private var helpText: String {
        let branch = entry.branch.map { " on \($0)" } ?? ""
        return "\(entry.selector)\(branch)"
    }
}

private struct GitWorktreeRow: View {
    let worktree: GitWorktree
    let isCurrent: Bool
    let openInNewWindow: () -> Void
    let remove: (() -> Void)?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(
                systemName: isCurrent
                    ? "checkmark.circle.fill" : "point.3.connected.trianglepath.dotted"
            )
            .foregroundStyle(isCurrent ? theme.palette.accent : theme.palette.textSecondary)
            .frame(width: 16)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(worktree.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(theme.palette.textPrimary)
                        .layoutPriority(1)
                    if worktree.isMain { RafuChip(text: "Main").fixedSize() }
                    if worktree.isLocked {
                        RafuChip(text: "Locked", foreground: theme.palette.warning).fixedSize()
                    }
                    if worktree.isPrunable {
                        RafuChip(text: "Prunable", foreground: theme.palette.error).fixedSize()
                    }
                }
                Text(worktree.path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = worktree.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if worktree.isDetached {
                    Text("Detached HEAD")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .tint(theme.palette.textSecondary)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Worktree Actions")
            .accessibilityLabel("Worktree Actions")
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openInNewWindow() }
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: worktree.path)])
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(worktree.path, forType: .string)
        }
        if let remove {
            Divider()
            Button("Remove Worktree…", systemImage: "trash", role: .destructive) { remove() }
        }
    }

    private var accessibilityText: String {
        var parts = ["Worktree \(worktree.name)"]
        if worktree.isMain { parts.append("main worktree") }
        if isCurrent { parts.append("current") }
        if let branch = worktree.branch { parts.append("branch \(branch)") }
        if worktree.isLocked { parts.append("locked") }
        if worktree.isPrunable { parts.append("prunable") }
        return parts.joined(separator: ", ")
    }
}

private struct GitAddWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkspaceSession
    @State private var path = ""
    @State private var branch = ""
    @State private var createBranch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "point.3.filled.connected.trianglepath.dotted",
                title: "Add Worktree",
                subtitle:
                    "Check out a branch into a separate folder — ideal for running a branch or a CLI coding agent in parallel."
            )

            Form {
                TextField("Folder path", text: $path, prompt: Text(defaultPathPrompt))
                Toggle("Create a new branch", isOn: $createBranch)
                TextField(
                    createBranch ? "New branch name" : "Existing branch to check out",
                    text: $branch)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Worktree") {
                    let resolvedPath = resolvedPath
                    let submittedBranch = branch
                    let submittedCreate = createBranch
                    Task {
                        await session.addWorktree(
                            at: resolvedPath, branch: submittedBranch,
                            createBranch: submittedCreate)
                        dismiss()
                    }
                }
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 460)
    }

    /// Sibling of the current workspace folder, matching the common
    /// `../repo-branch` worktree convention.
    private var defaultPathPrompt: String {
        guard let root = session.rootURL else { return "/path/to/worktree" }
        return root.deletingLastPathComponent().appending(path: "worktree").path
    }

    private var resolvedPath: URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return URL(filePath: defaultPathPrompt)
        }
        return URL(filePath: (trimmed as NSString).expandingTildeInPath)
    }

    private var isValid: Bool {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedBranch.isEmpty && !trimmedPath.isEmpty && !session.isGitBusy
    }
}

/// The three checkbox states a Source Control file row can present. Flat
/// mode only ever shows `.staged`/`.unstaged` (one per section); the unified
/// tree shows `.partial` for a file that is both staged and has further
/// unstaged worktree edits.
private enum GitChangeRowPresentation {
    case staged
    case partial
    case unstaged

    var symbolName: String {
        switch self {
        case .staged: "checkmark.square.fill"
        case .partial: "minus.square.fill"
        case .unstaged: "square"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .staged: "Staged"
        case .partial: "Partially staged"
        case .unstaged: "Not staged"
        }
    }
}

/// The status letter in a 16 pt rounded square (G2, G3): shape plus letter
/// plus colour, with the state name as tooltip and VoiceOver label. Letters
/// come from `GitStatusPresentation`, the same source the Files sidebar
/// badges use.
struct GitStatusLetterBadge: View {
    @Environment(\.rafuTheme) private var theme
    let kind: GitChangeKind

    var body: some View {
        let badge = GitTreeBadge(kind: kind, isDirectory: false)
        let color = badge.color(in: theme.palette)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Text(badge.shortCode)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: GitPanelMetrics.statusBadgeSize, height: GitPanelMetrics.statusBadgeSize)
            .background(shape.fill(color.opacity(0.14)))
            .overlay(shape.strokeBorder(color.opacity(0.5), lineWidth: RafuMetrics.hairline))
            .help(GitStatusPresentation.title(for: kind))
            .accessibilityLabel(GitStatusPresentation.title(for: kind))
    }
}

/// One-line (24 pt) file row (G2): checkbox, file icon, name, folder path in
/// secondary text only when the file is not at the root, status letter.
private struct GitChangeRow: View {
    @Environment(\.rafuTheme) private var theme
    let change: GitChange
    let presentation: GitChangeRowPresentation
    var showsFolder = true
    let toggleStaged: () -> Void

    var body: some View {
        let parts = GitChangePathParts(path: change.path)
        HStack(spacing: 6) {
            Button(action: toggleStaged) {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(
                        presentation == .unstaged
                            ? theme.palette.textMuted : theme.palette.accent)
            }
            .buttonStyle(.plain)
            .help(presentation == .staged ? "Unstage" : "Stage")
            .accessibilityLabel(presentation.accessibilityLabel)
            FileIconView(icon: FileIconProvider.fileIcon(named: parts.name), size: 12)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(parts.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if showsFolder, let folder = parts.folder {
                Text(folder)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            GitStatusLetterBadge(kind: change.kind)
        }
        .frame(height: GitPanelMetrics.fileRowHeight)
        .help(change.path)
        .listRowSeparator(.hidden)
    }
}

/// The Source Control tree mode's rows: chain-compacted folder rows with
/// tri-state checkboxes, and leaf file rows reusing `GitChangeRow`. Builds
/// its tree once per `changes` identity change rather than every `body`
/// evaluation.
private struct GitChangeTreeRows: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    let changes: [GitChange]
    // Built in init, not via onAppear/onChange: this view's body IS a
    // ForEach, and modifiers on a ForEach inside a List attach per row — with
    // an empty initial tree there are zero rows, so onAppear never fires and
    // the tree can never populate. Building here is a few hundred string
    // splits on event-driven parent re-evaluation, well within budget.
    private let tree: GitChangeTree

    @State private var collapsedFolderIDs: Set<String> = []

    private static let indentUnit: CGFloat = 14

    init(session: WorkspaceSession, changes: [GitChange]) {
        self.session = session
        self.changes = changes
        tree = GitChangeTreeBuilder.build(changes: changes)
    }

    var body: some View {
        ForEach(GitChangeTreeBuilder.visibleRows(tree: tree, collapsedIDs: collapsedFolderIDs)) {
            row in
            switch row {
            case .folder(let node, let depth):
                folderRow(node, depth: depth)
            case .file(let change, let depth):
                fileRow(change, depth: depth)
            }
        }
    }

    private func folderRow(_ node: GitChangeTreeNode, depth: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
                .rotationEffect(.degrees(collapsedFolderIDs.contains(node.id) ? 0 : 90))
                .frame(width: 10)
            Button {
                Task {
                    await session.setStaged(node.stagingState != .all, paths: node.descendantPaths)
                }
            } label: {
                Image(systemName: presentation(for: node.stagingState).symbolName)
                    .foregroundStyle(
                        node.stagingState == .none
                            ? theme.palette.textMuted : theme.palette.accent)
            }
            .buttonStyle(.plain)
            .help(node.stagingState == .all ? "Unstage folder" : "Stage folder")
            .accessibilityLabel(presentation(for: node.stagingState).accessibilityLabel)
            Image(systemName: "folder")
                .foregroundStyle(theme.palette.textSecondary)
            Text(node.displayName).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(node.fileCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(theme.palette.textMuted)
        }
        .frame(height: GitPanelMetrics.fileRowHeight)
        .padding(.leading, CGFloat(depth) * Self.indentUnit)
        .contentShape(.rect)
        .onTapGesture { toggleCollapsed(node.id) }
    }

    private func fileRow(_ change: GitChange, depth: Int) -> some View {
        let isFullyStaged = change.isStaged && !change.hasUnstagedChanges
        let openScope: GitDiffScope = change.hasUnstagedChanges ? .workingTree : .staged
        return GitChangeRow(
            change: change,
            presentation: presentation(for: change),
            showsFolder: false,
            toggleStaged: {
                Task { await session.setStaged(!isFullyStaged, change: change) }
            }
        )
        .tag(change.id)
        .padding(.leading, CGFloat(depth) * Self.indentUnit)
        .contentShape(.rect)
        .onTapGesture {
            Task { await session.gitOpenChangeDiff(change, scope: openScope) }
        }
        .contextMenu {
            if change.isStaged {
                Button("Open Staged Diff", systemImage: "arrow.left.arrow.right") {
                    Task { await session.gitOpenChangeDiff(change, scope: .staged) }
                }
            }
            if change.hasUnstagedChanges {
                Button("Open Working Tree Diff", systemImage: "arrow.left.arrow.right") {
                    Task { await session.gitOpenChangeDiff(change, scope: .workingTree) }
                }
            }
            Divider()
            Button(
                isFullyStaged ? "Unstage" : "Stage",
                systemImage: isFullyStaged ? "minus.circle" : "plus.circle"
            ) {
                Task { await session.setStaged(!isFullyStaged, change: change) }
            }
        }
    }

    private func toggleCollapsed(_ id: String) {
        if collapsedFolderIDs.contains(id) {
            collapsedFolderIDs.remove(id)
        } else {
            collapsedFolderIDs.insert(id)
        }
    }

    private func presentation(for change: GitChange) -> GitChangeRowPresentation {
        if change.isStaged && !change.hasUnstagedChanges { return .staged }
        if !change.isStaged { return .unstaged }
        return .partial
    }

    private func presentation(for stagingState: GitChangeStagingState) -> GitChangeRowPresentation {
        switch stagingState {
        case .all: .staged
        case .some: .partial
        case .none: .unstaged
        }
    }
}
