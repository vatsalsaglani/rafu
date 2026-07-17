import SwiftUI

struct GitInspectorView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    @State private var isCreatingBranch = false
    @State private var isStashSheetPresented = false
    @State private var isStashesExpanded = true
    @State private var newBranchName = ""
    @State private var pendingMergeBranch: String?
    @State private var pendingStashAction: PendingStashAction?
    @AppStorage("gitChangesViewMode") private var gitChangesViewModeRaw =
        GitChangesViewMode.flat.rawValue

    private var changesViewMode: GitChangesViewMode {
        GitChangesViewMode(rawValue: gitChangesViewModeRaw) ?? .flat
    }

    var body: some View {
        VStack(spacing: 0) {
            repositoryHeader
            if let mergeState = session.gitMergeState {
                mergeBanner(mergeState)
            }
            Divider()
            RafuSegmentedPicker(
                items: GitInspectorSection.allCases,
                selection: $session.gitInspectorSection,
                title: \.title
            )
            .padding(10)

            switch session.gitInspectorSection {
            case .changes:
                changesView
            case .history:
                historyView
            }
        }
        .frame(minWidth: 250, idealWidth: 310)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if session.isGitBusy {
                ProgressView().controlSize(.small).padding(10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
            }
        }
        .task(id: session.rootURL) { await refreshAllGitState() }
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

    private var repositoryHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                branchMenu
                Spacer(minLength: 4)
                syncMenu
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refreshAllGitState() }
                }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .help("Refresh Source Control")
            }
            if let branches = session.gitBranchSnapshot {
                HStack(spacing: 10) {
                    if let upstream = branches.upstream {
                        Label(upstream, systemImage: "cloud")
                            .lineLimit(1)
                    } else {
                        Label("No upstream", systemImage: "icloud.slash")
                    }
                    Spacer()
                    if branches.aheadCount > 0 {
                        Label("\(branches.aheadCount)", systemImage: "arrow.up")
                            .help("Commits ahead")
                    }
                    if branches.behindCount > 0 {
                        Label("\(branches.behindCount)", systemImage: "arrow.down")
                            .help("Commits behind")
                    }
                }
                .font(.caption2)
                .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .padding(10)
    }

    private var branchMenu: some View {
        Menu {
            if let branches = session.gitBranchSnapshot {
                Section("Local Branches") {
                    ForEach(branches.localBranches) { branch in
                        Button {
                            guard !branch.isCurrent else { return }
                            Task { await session.gitCheckoutBranch(named: branch.name) }
                        } label: {
                            Label(
                                branch.name,
                                systemImage: branch.isCurrent ? "checkmark" : "arrow.right"
                            )
                        }
                        .disabled(branch.isCurrent)
                    }
                }
                if !branches.remoteBranches.isEmpty {
                    Section("Remote Branches") {
                        ForEach(branches.remoteBranches) { branch in
                            Button(branch.name) {
                                Task { await session.gitCheckoutBranch(named: branch.name) }
                            }
                        }
                    }
                }
                Menu("Merge into Current", systemImage: "arrow.triangle.merge") {
                    ForEach(branches.localBranches.filter { !$0.isCurrent }) { branch in
                        Button(branch.name) { pendingMergeBranch = branch.name }
                    }
                }
                .disabled(branches.localBranches.allSatisfy(\.isCurrent))
            }
            Divider()
            Button("Create Branch…", systemImage: "plus") { isCreatingBranch = true }
        } label: {
            Label(snapshot.branch, systemImage: "arrow.triangle.branch")
                .font(.headline)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch, create, or merge branches")
    }

    private var syncMenu: some View {
        Menu {
            Button("Fetch All", systemImage: "arrow.clockwise") {
                Task { await session.gitFetch() }
            }
            Menu("Pull", systemImage: "arrow.down.circle") {
                Button("Merge") { Task { await session.gitPull(strategy: .merge) } }
                Button("Rebase") { Task { await session.gitPull(strategy: .rebase) } }
                Button("Fast-Forward Only") {
                    Task { await session.gitPull(strategy: .fastForwardOnly) }
                }
            }
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
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .menuStyle(.borderlessButton)
        .help("Fetch, pull, or push")
    }

    private var changesView: some View {
        VStack(spacing: 0) {
            changesHeader
            if snapshot.changes.isEmpty && session.gitStashes.isEmpty {
                // Expand so the commit composer pins to the panel bottom
                // instead of floating mid-panel with dead space beneath.
                ContentUnavailableView(
                    "Working tree clean",
                    systemImage: "checkmark.circle",
                    description: Text("There are no local changes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
            commitComposer
        }
    }

    private var changesHeader: some View {
        HStack(spacing: 6) {
            Text(
                "\(snapshot.changes.count) changed \(snapshot.changes.count == 1 ? "file" : "files")"
            )
            .font(.caption2)
            .foregroundStyle(theme.palette.textMuted)
            Spacer(minLength: 4)
            Button("Stash Changes", systemImage: "archivebox") {
                isStashSheetPresented = true
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 11))
            .disabled(snapshot.changes.isEmpty || session.isGitBusy)
            .help("Stash working-tree changes explicitly")
            Button("Flat List", systemImage: "list.bullet") {
                gitChangesViewModeRaw = GitChangesViewMode.flat.rawValue
            }
            .buttonStyle(
                RafuIconButtonStyle(isActive: changesViewMode == .flat, size: 22, iconSize: 11)
            )
            .help("Show changes as a flat list")
            Button("Grouped by Folder", systemImage: "folder") {
                gitChangesViewModeRaw = GitChangesViewMode.tree.rawValue
            }
            .buttonStyle(
                RafuIconButtonStyle(isActive: changesViewMode == .tree, size: 22, iconSize: 11)
            )
            .help("Group changes by folder")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
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
            Button(scope == .staged ? "Open Staged Diff" : "Open Working Tree Diff") {
                Task { await session.gitOpenChangeDiff(change, scope: scope) }
            }
            Divider()
            Button(scope == .staged ? "Unstage" : "Stage") {
                Task { await session.setStaged(scope != .staged, change: change) }
            }
        }
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commit").font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.textMuted)
                    .textCase(.uppercase)
                    .kerning(0.5)
                Spacer()
                if session.isGeneratingAICommitMessage {
                    ProgressView().controlSize(.mini)
                }
                Button("Generate Commit Message", systemImage: "sparkles") {
                    Task { await session.generateAICommitMessage() }
                }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .disabled(!session.canGenerateAICommitMessage)
                .help(
                    "Generate from \(session.aiCommitGenerationScopeDescription). No commit is created automatically."
                )
            }
            Text("Generate scope: \(session.aiCommitGenerationScopeDescription)")
                .font(.caption2)
                .foregroundStyle(theme.palette.textMuted)
            TextField("Commit message", text: $session.gitCommitMessage, axis: .vertical)
                .lineLimit(2...5)
            if let error = session.aiCommitGenerationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.error)
            }
            HStack {
                Button("Stage All") { Task { await session.stageAll() } }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Spacer()
                Button("Commit") { Task { await session.commit() } }
                    .buttonStyle(RafuProminentButtonStyle(compact: true))
                    .disabled(
                        session.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty || snapshot.stagedChanges.isEmpty
                            || session.isGeneratingAICommitMessage
                    )
            }
        }
        .padding(10)
        .background(theme.palette.elevatedBackground.opacity(0.65))
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
    }

    private var historyView: some View {
        VStack(spacing: 0) {
            if let commits = session.gitHistoryPage?.commits, !commits.isEmpty {
                List(selection: $session.gitSelectedHistoryCommitID) {
                    Section("Commits") {
                        ForEach(commits) { commit in
                            GitHistoryRow(commit: commit)
                                .tag(commit.id)
                                .contentShape(.rect)
                                .onTapGesture {
                                    Task { await session.gitSelectHistoryCommit(commit) }
                                }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                if let commit = selectedHistoryCommit {
                    Divider()
                    GitHistoryDetail(
                        commit: commit,
                        changes: session.gitHistoryCommitChanges,
                        isLoading: session.isGitHistoryDetailLoading,
                        openDiff: { change in
                            Task { await session.gitOpenHistoryDiff(change) }
                        }
                    )
                    .frame(maxHeight: 260)
                }
            } else {
                ContentUnavailableView(
                    "No commits yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Commit history will appear here.")
                )
            }
        }
    }

    private var selectedHistoryCommit: GitCommitSummary? {
        guard let id = session.gitSelectedHistoryCommitID else { return nil }
        return session.gitHistoryPage?.commits.first { $0.id == id }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Stash Changes")
                    .font(.title2.weight(.semibold))
                Text("Save the current working tree explicitly. Rafu never stashes automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Message (Optional)", text: $message, axis: .vertical)
                    .lineLimit(2...4)
                Toggle("Include untracked files", isOn: $includeUntracked)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
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
                .buttonStyle(.borderedProminent)
                .disabled(session.gitSnapshot?.changes.isEmpty != false || session.isGitBusy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct GitStashRow: View {
    let entry: GitStashEntry
    let apply: () -> Void
    let requestPop: () -> Void
    let requestDrop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if let branch = entry.branch {
                        Text(branch)
                    }
                    Text(entry.selector)
                    Text(entry.createdAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            Spacer(minLength: 4)
            Menu("Stash Actions", systemImage: "ellipsis.circle") {
                actions
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Apply Stash", systemImage: "arrow.down.doc") { apply() }
        Button("Pop Stash…", systemImage: "arrow.down.doc.fill") { requestPop() }
        Divider()
        Button("Drop Stash…", systemImage: "trash", role: .destructive) { requestDrop() }
    }

    private var accessibilityText: String {
        let branch = entry.branch.map { ", branch \($0)" } ?? ""
        return "Stash \(entry.index), \(entry.message)\(branch)"
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

private struct GitChangeRow: View {
    @Environment(\.rafuTheme) private var theme
    let change: GitChange
    let presentation: GitChangeRowPresentation
    let toggleStaged: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: toggleStaged) {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(
                        presentation == .unstaged
                            ? theme.palette.textMuted : theme.palette.accent)
            }
            .buttonStyle(.plain)
            .help(presentation == .staged ? "Unstage" : "Stage")
            .accessibilityLabel(presentation.accessibilityLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text((change.path as NSString).lastPathComponent).lineLimit(1)
                Text(change.path).font(.caption2)
                    .foregroundStyle(theme.palette.textMuted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(statusSymbol)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(statusColor)
                .accessibilityLabel(change.statusLabel)
        }
    }

    private var statusSymbol: String {
        switch change.kind {
        case .added, .untracked: "A"
        case .copied: "C"
        case .conflicted: "!"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .typeChanged: "T"
        case .unknown: "•"
        }
    }

    private var statusColor: Color {
        switch change.kind {
        case .added, .copied: theme.palette.gitAdded
        case .untracked: theme.palette.gitUntracked
        case .deleted: theme.palette.gitDeleted
        case .conflicted: theme.palette.gitConflict
        case .renamed, .typeChanged: theme.palette.gitRenamed
        case .modified, .unknown: theme.palette.gitModified
        }
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
                Button("Open Staged Diff") {
                    Task { await session.gitOpenChangeDiff(change, scope: .staged) }
                }
            }
            if change.hasUnstagedChanges {
                Button("Open Working Tree Diff") {
                    Task { await session.gitOpenChangeDiff(change, scope: .workingTree) }
                }
            }
            Divider()
            Button(isFullyStaged ? "Unstage" : "Stage") {
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

private struct GitHistoryRow: View {
    @Environment(\.rafuTheme) private var theme
    let commit: GitCommitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.subject).font(.callout.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                Text(commit.shortID).font(.caption2.monospaced())
                Text(commit.authorName).lineLimit(1)
                Spacer()
                Text(commit.authoredAt, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if !commit.decorations.isEmpty {
                Text(commit.decorations.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(theme.palette.info)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct GitHistoryDetail: View {
    @Environment(\.rafuTheme) private var theme
    let commit: GitCommitSummary
    let changes: [GitCommitFileChange]
    let isLoading: Bool
    let openDiff: (GitCommitFileChange) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(commit.subject).font(.headline).textSelection(.enabled)
                Text("\(commit.authorName) <\(commit.authorEmail)>")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(commit.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if changes.isEmpty {
                    Text("This commit has no file changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(changes) { change in
                        Button {
                            openDiff(change)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(change.path).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Open diff for \(change.path)")
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.palette.elevatedBackground.opacity(0.5))
    }
}
