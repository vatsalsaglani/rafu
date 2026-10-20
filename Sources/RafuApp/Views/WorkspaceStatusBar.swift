import RafuCore
import SwiftUI

struct WorkspaceStatusBar: View {
    @AppStorage("showsProcessMemory") private var showsProcessMemory = false
    @Environment(\.rafuTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @Bindable var session: WorkspaceSession
    /// Shared with the Resources popover so both always show the same reading.
    private var memory = ResidentMemoryMonitor.shared
    private var motionGate = RafuMotionGate.shared

    init(session: WorkspaceSession) {
        self.session = session
    }

    private var descriptor: WorkspaceDescriptor? { session.descriptor }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(descriptor == nil ? theme.palette.textMuted : theme.palette.success)
                    .frame(width: 6, height: 6)
                Label(statusText, systemImage: statusSymbol)
                    .lineLimit(1)
            }

            // The branch of the repository that holds the editor file. When
            // that is not the Source Control repository, a click selects it
            // in Source Control; the selection never changes on its own.
            if let other = session.activeDocumentRepositoryOutsideSourceControl {
                summaryChip(
                    StatusBarBranchFormatter.present(summary: other.summary),
                    repositoryName: other.repository.displayName,
                    action: {
                        session.selectGitRepository(other.repository.id)
                        session.showNavigator(.sourceControl)
                    },
                    help: "Show \(other.repository.displayName) in Source Control")
            } else if let branchSnapshot = session.gitBranchSnapshot {
                branchControl(branchSnapshot)
            } else if let summary = session.sourceControlBranchSummary {
                // Branches load with Source Control; until then the status
                // snapshot from opening the workspace names the branch.
                summaryChip(
                    StatusBarBranchFormatter.present(summary: summary),
                    repositoryName: repositoryNameForChip,
                    action: { session.showNavigator(.sourceControl) },
                    help: "Show Source Control")
            }

            Spacer()

            agentActivity

            GitHubAccountStatusView(session: session)

            if showsProcessMemory, let sample = memory.sample {
                Label(ResourceMemoryFormat.label(sample.displayBytes), systemImage: "memorychip")
                    .foregroundStyle(theme.palette.textMuted)
                    .help(
                        "Rafu process memory footprint, as Activity Monitor shows it. "
                            + "This is shared by all windows.")
            }

            Button {
                session.isResourcesPresented.toggle()
            } label: {
                Image(systemName: "memorychip")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.textMuted)
            .accessibilityLabel("Show Resources")
            .help("Show Resources")
            .popover(isPresented: $session.isResourcesPresented) {
                ResourcesView(coordinator: session.languageIntelligence, session: session)
            }

            if let servers = StatusBarLanguageServerFormatter.present(
                phases: session.languageIntelligence.servers.statuses.values.map(\.phase))
            {
                Button {
                    session.isResourcesPresented = true
                } label: {
                    Label(servers.label, systemImage: servers.symbol)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.palette.textMuted)
                .help(servers.help)
                .accessibilityLabel(servers.help)
            }

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.textMuted)
            .accessibilityLabel("Open Settings")
            .help("Open Settings")
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.palette.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: RafuMetrics.statusBarHeight)
        .background(theme.palette.statusBarBackground)
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
        // Pauses while the screen is locked or the displays sleep; the task
        // restarts, and reads at once, when they come back.
        .task(id: showsProcessMemory && motionGate.isScreenActive) {
            guard showsProcessMemory, motionGate.isScreenActive else { return }
            while !Task.isCancelled {
                memory.refresh()
                do {
                    try await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    /// Running agent sessions, with their vendor marks. Hidden when none run.
    /// The count is words, not colour; the button opens the Terminals panel.
    @ViewBuilder
    private var agentActivity: some View {
        let summary = AgentActivitySummary(sessions: session.terminal.sessions)
        if summary.isActive {
            Button {
                session.showNavigator(.terminals)
            } label: {
                HStack(spacing: 5) {
                    HStack(spacing: -2) {
                        ForEach(summary.providers.prefix(3), id: \.self) { cli in
                            AgentIconView(cli: cli, size: 13)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(summary.label)
                        .lineLimit(1)
                    if summary.attentionLabel != nil {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 10))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("\(summary.accessibilityLabel). Show Terminals.")
            .accessibilityLabel(summary.accessibilityLabel)
        }
    }

    private var statusText: String {
        guard let descriptor else {
            return "No workspace"
        }

        switch descriptor.location {
        case .local:
            return "Local"
        case .ssh(let reference):
            return reference.hostAlias
        }
    }

    private var statusSymbol: String {
        guard let descriptor else {
            return "circle.dashed"
        }

        switch descriptor.location {
        case .local:
            return "internaldrive"
        case .ssh:
            return "network"
        }
    }

    /// Bottom-bar branch chip (GD/GI 11): shows the current git branch when
    /// the workspace is a repo and switches branches without opening Source
    /// Control, via the same reusable `RafuSearchableDropdown` used by the
    /// Source Control branch switcher.
    private func branchControl(_ snapshot: GitBranchSnapshot) -> some View {
        let presentation = StatusBarBranchFormatter.present(snapshot)
        return RafuSearchableDropdown(
            items: snapshot.localBranches + snapshot.remoteBranches,
            text: \.name,
            keywords: { [$0.name] },
            isCurrent: \.isCurrent,
            onSelect: { branch in
                guard !branch.isCurrent else { return }
                Task { await session.gitCheckoutBranch(named: branch.name) }
            },
            searchPrompt: "Search branches",
            sectionTitle: { $0.kind == .local ? "Local" : "Remote" }
        ) {
            branchLabel(presentation, repositoryName: repositoryNameForChip)
        }
        .help(
            presentation.isDetached
                ? "Detached HEAD — select a branch to check out"
                : "Current branch \(presentation.label) — switch branches"
        )
        .accessibilityLabel(
            presentation.isDetached
                ? "Detached HEAD, switch branches"
                : "Current branch \(presentation.label), switch branches")
    }

    /// The Source Control repository's name, shown only when the workspace
    /// has more than one repository.
    private var repositoryNameForChip: String? {
        guard session.gitRepositories.count > 1 else { return nil }
        return session.selectedGitRepository?.displayName
    }

    private func branchLabel(
        _ presentation: StatusBarBranchFormatter.Presentation, repositoryName: String?
    ) -> some View {
        HStack(spacing: RafuMetrics.space1) {
            Image(systemName: "arrow.triangle.branch")
            if let repositoryName {
                Text(repositoryName)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(presentation.label)
                .lineLimit(1)
                .truncationMode(.middle)
            if presentation.isDetached {
                Text("detached")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(theme.palette.textMuted)
            }
            if let aheadText = presentation.aheadText {
                Label(aheadText, systemImage: "arrow.up")
            }
            if let behindText = presentation.behindText {
                Label(behindText, systemImage: "arrow.down")
            }
        }
        .lineLimit(1)
    }

    /// A branch chip from a repository summary: a plain button, because
    /// switching branches needs the full branch list of Source Control.
    private func summaryChip(
        _ presentation: StatusBarBranchFormatter.Presentation, repositoryName: String?,
        action: @escaping () -> Void, help: String
    ) -> some View {
        Button(action: action) {
            branchLabel(presentation, repositoryName: repositoryName)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(
            [
                repositoryName.map { "Repository \($0)" },
                presentation.isDetached
                    ? "Detached HEAD" : "Branch \(presentation.label)",
            ].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityHint(help)
    }
}

/// Pure formatting for the status bar's language-server item. It reports a
/// count and the worst state, with a shape-distinct symbol as well as words.
/// No servers running means no item at all.
nonisolated enum StatusBarLanguageServerFormatter {
    struct Presentation: Equatable {
        let label: String
        let symbol: String
        let help: String
    }

    static func present(phases: [LanguageServerStatus.Phase]) -> Presentation? {
        guard !phases.isEmpty else { return nil }
        let stopped = phases.filter { $0 == .dead || $0 == .ceilingKilled }.count
        let starting = phases.filter {
            $0 == .starting || $0 == .warmingUp || $0 == .backingOff
        }.count
        let noun = phases.count == 1 ? "language server" : "language servers"
        if stopped > 0 {
            return Presentation(
                label: "\(stopped) stopped",
                symbol: "exclamationmark.triangle",
                help: "\(stopped) of \(phases.count) \(noun) stopped. Open Resources to restart."
            )
        }
        if starting > 0 {
            return Presentation(
                label: "\(starting) starting",
                symbol: "hourglass",
                help: "\(starting) of \(phases.count) \(noun) starting"
            )
        }
        return Presentation(
            label: "\(phases.count) \(noun)",
            symbol: "cpu",
            help: "\(phases.count) \(noun) running. Open Resources for details."
        )
    }
}

/// Pure, UI-free formatting for the status bar branch chip, kept separate
/// from the view so it is unit testable without instantiating SwiftUI.
nonisolated enum StatusBarBranchFormatter {
    struct Presentation: Equatable {
        let label: String
        let isDetached: Bool
        let aheadText: String?
        let behindText: String?
    }

    static func present(_ snapshot: GitBranchSnapshot) -> Presentation {
        Presentation(
            label: snapshot.currentBranch ?? "HEAD",
            isDetached: snapshot.isDetached,
            aheadText: snapshot.aheadCount > 0 ? "\(snapshot.aheadCount)" : nil,
            behindText: snapshot.behindCount > 0 ? "\(snapshot.behindCount)" : nil
        )
    }

    /// The same chip from a repository summary (another repository, or the
    /// Source Control repository before its branches load).
    static func present(summary: GitRepositorySummary) -> Presentation {
        Presentation(
            label: summary.isDetached ? "HEAD" : summary.branch,
            isDetached: summary.isDetached,
            aheadText: summary.aheadCount > 0 ? "\(summary.aheadCount)" : nil,
            behindText: summary.behindCount > 0 ? "\(summary.behindCount)" : nil
        )
    }
}
