import RafuCore
import SwiftUI

struct WorkspaceStatusBar: View {
    @AppStorage("showsProcessMemory") private var showsProcessMemory = false
    @Environment(\.rafuTheme) private var theme
    @State private var memorySample: ProcessMemorySample?
    @Bindable var session: WorkspaceSession

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

            if let branchSnapshot = session.gitBranchSnapshot {
                branchControl(branchSnapshot)
            }

            Spacer()

            if showsProcessMemory, let memorySample {
                Label(memorySample.formatted, systemImage: "memorychip")
                    .foregroundStyle(theme.palette.textMuted)
                    .help("Rafu process resident memory. This is shared by all windows.")
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
                ResourcesView(coordinator: session.languageIntelligence)
            }

            Text(descriptor == nil ? "Ready" : "Local editor")
                .foregroundStyle(theme.palette.textMuted)
        }
        .font(.caption)
        .foregroundStyle(theme.palette.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: RafuMetrics.statusBarHeight)
        .background(theme.palette.statusBarBackground)
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
        .task(id: showsProcessMemory) {
            guard showsProcessMemory else {
                memorySample = nil
                return
            }
            let sampler = ProcessMemorySampler()
            while !Task.isCancelled {
                memorySample = sampler.sample()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
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
            searchPrompt: "Search branches"
        ) {
            HStack(spacing: RafuMetrics.space1) {
                Image(systemName: "arrow.triangle.branch")
                Text(presentation.label).lineLimit(1)
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
        .help(
            presentation.isDetached
                ? "Detached HEAD — select a branch to check out"
                : "Switch branches"
        )
        .accessibilityLabel(
            presentation.isDetached
                ? "Detached HEAD, switch branches"
                : "Current branch \(presentation.label), switch branches")
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
}
