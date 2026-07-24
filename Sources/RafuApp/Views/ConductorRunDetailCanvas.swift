import SwiftUI

/// Editor-hosted Ensemble run detail (C5): a vertical timeline of steps, gate
/// verbs, and the terminal merge gate. ADR 0002/0003's pattern — run
/// STRUCTURE lives in the Runs navigator panel, run DETAIL lives here, never
/// in a permanent inspector. Routed from `EditorCanvasView` the same way
/// `GitStandaloneDiffCanvas` is: an additive branch keyed on
/// `session.conductorRunCanvasID`.
struct ConductorRunDetailCanvas: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    @State private var isHoveringCloseTab = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(theme.palette.borderSubtle)
            if let manifest {
                RunDetailContent(
                    session: session,
                    manifest: manifest,
                    isActiveRun: isActiveRun(manifest)
                )
            } else {
                ContentUnavailableView(
                    "No Run Selected",
                    systemImage: WorkspaceNavigatorMode.runs.symbolName,
                    description: Text("Choose a run in the Runs navigator to see its detail.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.palette.editorBackground)
    }

    /// Prefers the workflow controller's LIVE manifest when this canvas is
    /// showing the run it is currently driving (so a step transition is
    /// visible the instant it happens); falls back to the persisted
    /// snapshot in `session.conductorRuns` for a historical run.
    private var manifest: ConductorRunManifest? {
        guard let runID = session.conductorRunCanvasID else { return nil }
        if session.conductorWorkflowController.manifest?.id == runID {
            return session.conductorWorkflowController.manifest
        }
        return session.conductorRuns.first(where: { $0.id == runID })
    }

    private func isActiveRun(_ manifest: ConductorRunManifest) -> Bool {
        session.conductorWorkflowController.manifest?.id == manifest.id
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: WorkspaceNavigatorMode.runs.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.info)
                Text(manifest.map { "Run • \($0.workflowName)" } ?? "Run")
                    .lineLimit(1)
                    .foregroundStyle(theme.palette.textPrimary)
                Button("Close Run", systemImage: "xmark", action: session.closeConductorRunDetail)
                    .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                    .opacity(isHoveringCloseTab ? 1 : 0.75)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: RafuMetrics.tabBarHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.palette.accent).frame(height: 2)
            }
            .overlay(alignment: .trailing) {
                Divider().frame(height: 18).overlay(theme.palette.borderSubtle)
            }
            .onHover { isHoveringCloseTab = $0 }
            Spacer()
        }
        .frame(height: RafuMetrics.tabBarHeight)
        .background(theme.palette.tabBarBackground)
    }
}

/// Split out of `ConductorRunDetailCanvas.body` so the timeline's own state
/// (discard confirmations) resets cleanly whenever the shown run changes —
/// `.id(manifest.id)` on the caller gives this a fresh identity per run.
private struct RunDetailContent: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    let manifest: ConductorRunManifest
    let isActiveRun: Bool

    var body: some View {
        @Bindable var workflow = session.conductorWorkflowController
        ScrollView {
            VStack(alignment: .leading, spacing: RafuMetrics.space3) {
                headerCard
                LazyVStack(alignment: .leading, spacing: RafuMetrics.space3) {
                    ForEach(stepRows) { row in
                        ConductorStepTimelineRow(
                            row: row,
                            isActiveRun: isActiveRun,
                            isFailedStep: failedStepIndex == row.index,
                            openArtifact: {
                                session.openFile(atRelativePath: row.artifactRelativePath)
                            },
                            revealTerminal: {
                                workflow.revealLiveTerminal(stepIndex: row.index, in: session)
                            },
                            approve: { Task { await workflow.approveGate() } },
                            revise: { workflow.reviseArtifact(in: session) },
                            retry: { Task { await workflow.retryFailedStep() } }
                        )
                    }
                }
                if isActiveRun, manifest.gate?.kind == .merge {
                    ConductorMergeGateSection(
                        files: workflow.mergeGateFiles,
                        error: workflow.mergeGateError,
                        hasApplied: workflow.hasAppliedToWorkspace,
                        isResolving: workflow.isResolvingMergeGate,
                        apply: { Task { await workflow.applyToWorkspace() } },
                        keep: { Task { await workflow.keepWorktree() } },
                        discard: { confirmedDirty in
                            await workflow.discardWorktree(confirmedDirty: confirmedDirty)
                        },
                        openDiff: { file in
                            Task { await workflow.presentMergeGateDiff(file, in: session) }
                        }
                    )
                }
            }
            .padding(RafuMetrics.space4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var headerCard: some View {
        RafuCardHeaderRow {
            HStack(spacing: 8) {
                Image(systemName: WorkspaceNavigatorMode.runs.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.info)
                Text(manifest.workflowName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                RafuChip(
                    text: manifest.worktreeBranch.isEmpty
                        ? "Main workspace" : manifest.worktreeBranch
                )
            }
        } trailing: {
            HStack(spacing: 8) {
                RafuChip(text: String(manifest.baseCommit.prefix(8)), monospacedDigit: true)
                if isActiveRun, session.conductorWorkflowController.isInFlight {
                    Button("Abort Run", systemImage: "xmark.circle", role: .destructive) {
                        session.conductorWorkflowController.abort()
                    }
                    .buttonStyle(RafuSecondaryButtonStyle())
                }
            }
        }
    }

    private var stepRows: [ConductorStepRowModel] {
        let liveIndex =
            isActiveRun
            ? ConductorRunPresentation.liveStepIndex(in: session.conductorWorkflowController.state)
            : nil
        return ConductorRunPresentation.stepRows(for: manifest, liveStepIndex: liveIndex)
    }

    private var failedStepIndex: Int? {
        guard isActiveRun, case .failed(let index, _) = session.conductorWorkflowController.state
        else { return nil }
        return index
    }
}

/// One step's card: role identity, provider/model chips, symbol+text status,
/// duration/attempt, and its reachable verbs — every verb a real `Button`
/// with a text label (AGENTS: no icon-only, no gesture-only actions).
private struct ConductorStepTimelineRow: View {
    @Environment(\.rafuTheme) private var theme
    let row: ConductorStepRowModel
    let isActiveRun: Bool
    let isFailedStep: Bool
    let openArtifact: () -> Void
    let revealTerminal: () -> Void
    let approve: () -> Void
    let revise: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Step \(row.index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.textMuted)
                Text(row.agentName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: row.statusSymbol)
                    .foregroundStyle(statusTint)
                Text(row.statusLabel)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                RafuChip(text: row.providerLabel, foreground: theme.palette.textSecondary)
                RafuChip(text: row.modelLabel, foreground: theme.palette.textSecondary)
                if let durationLabel = row.durationLabel {
                    RafuChip(text: durationLabel, monospacedDigit: true)
                }
                if let attemptLabel = row.attemptLabel {
                    RafuChip(text: attemptLabel)
                }
            }
            HStack(spacing: 8) {
                Button("Open Artifact", action: openArtifact)
                    .buttonStyle(RafuSecondaryButtonStyle())
                if row.hasLiveTerminal {
                    Button("Reveal Terminal", action: revealTerminal)
                        .buttonStyle(RafuSecondaryButtonStyle())
                }
                if isActiveRun, row.isGateReady {
                    Button("Approve", action: approve)
                        .buttonStyle(RafuProminentButtonStyle())
                    Button("Revise", action: revise)
                        .buttonStyle(RafuSecondaryButtonStyle())
                }
                if isActiveRun, isFailedStep {
                    Button("Retry Step", action: retry)
                        .buttonStyle(RafuProminentButtonStyle())
                }
            }
        }
        .padding(RafuMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .fill(theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(row.index + 1), \(row.agentName), \(row.statusLabel)")
    }

    private var statusTint: Color {
        switch row.statusSymbol {
        case "exclamationmark.triangle.fill": theme.palette.gitDeleted
        case "pause.circle.fill": theme.palette.accent
        case "checkmark.circle.fill": theme.palette.gitAdded
        default: theme.palette.textSecondary
        }
    }
}

/// The one terminal merge gate — reused verbatim from C1's contract
/// (`ConductorMergeGateService`/`ConductorWorktreeService`), now with a real
/// UI. Discard keeps the two-step confirmation: an uncommitted-changes
/// worktree needs an explicit second confirmation before Rafu deletes it.
private struct ConductorMergeGateSection: View {
    @Environment(\.rafuTheme) private var theme
    let files: [ConductorMergeGateFile]
    let error: String?
    let hasApplied: Bool
    let isResolving: Bool
    let apply: () -> Void
    let keep: () -> Void
    let discard: (Bool) async -> ConductorWorktreeDiscardResult?
    let openDiff: (ConductorMergeGateFile) -> Void

    @State private var isDiscardConfirmationPresented = false
    @State private var isDirtyConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge Gate")
                .font(.headline)
                .foregroundStyle(theme.palette.textPrimary)
            Text("Review the run worktree's changes, then choose how to resolve it.")
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(theme.palette.gitDeleted)
            }
            if files.isEmpty {
                Text("No changes were recorded in the run worktree.")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files) { file in
                        Button {
                            openDiff(file)
                        } label: {
                            HStack(spacing: 6) {
                                Image(
                                    systemName: file.isUntracked
                                        ? "plus.circle" : "pencil.circle"
                                )
                                .foregroundStyle(
                                    file.isUntracked
                                        ? theme.palette.gitAdded : theme.palette.info)
                                Text(file.path)
                                    .foregroundStyle(theme.palette.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Apply to Workspace", action: apply)
                    .buttonStyle(RafuProminentButtonStyle())
                    .disabled(isResolving || hasApplied)
                Button("Keep Worktree", action: keep)
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .disabled(isResolving)
                Button("Discard…", role: .destructive) {
                    isDiscardConfirmationPresented = true
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                .disabled(isResolving)
            }
        }
        .padding(RafuMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .fill(theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .alert("Discard the Run Worktree?", isPresented: $isDiscardConfirmationPresented) {
            Button("Discard", role: .destructive) {
                Task {
                    if await discard(false) == .confirmationRequired {
                        isDirtyConfirmationPresented = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the run's worktree and branch. Applied or kept changes are unaffected."
            )
        }
        .alert("The Worktree Has Uncommitted Changes", isPresented: $isDirtyConfirmationPresented) {
            Button("Discard Anyway", role: .destructive) {
                Task { _ = await discard(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Discarding now permanently removes those changes.")
        }
    }
}
