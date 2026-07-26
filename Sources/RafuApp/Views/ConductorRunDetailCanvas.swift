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
                // Fresh identity per run: `RunDetailContent`'s own state
                // (discard confirmations) must reset when the shown run
                // changes, not linger from whichever run was showing before.
                .id(manifest.id)
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
        if let live = session.workflowController(forRunID: runID)?.manifest, live.id == runID {
            return live
        }
        return session.conductorRuns.first(where: { $0.id == runID })
    }

    /// A run is "active" here when some live engine in this window still owns
    /// it — that engine may be one of C6's concurrent controllers, not just
    /// the window's singular one.
    private func isActiveRun(_ manifest: ConductorRunManifest) -> Bool {
        session.workflowController(forRunID: manifest.id)?.manifest?.id == manifest.id
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: WorkspaceNavigatorMode.runs.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.info)
                    .accessibilityHidden(true)
                Text(manifest.map { "Run • \($0.workflowName)" } ?? "Run")
                    .lineLimit(1)
                    .foregroundStyle(theme.palette.textPrimary)
                Button("Close Run", systemImage: "xmark", action: session.closeConductorRunDetail)
                    .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                    .opacity(isHoveringCloseTab ? 1 : 0.75)
                    .accessibilityHint("Closes the Ensemble run detail")
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
/// `ConductorRunDetailCanvas.body` applies `.id(manifest.id)` to this view at
/// its call site, giving it a fresh identity per run.
private struct RunDetailContent: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    let manifest: ConductorRunManifest
    let isActiveRun: Bool
    @State private var notes: [ConductorEnsembleNoteStore.Note] = []

    var body: some View {
        // The engine owning THIS run (C6: one of several concurrent
        // controllers, or the window's singular one). `nil` for a historical
        // run — every verb below is already gated on `isActiveRun`, so the
        // optional chaining is belt-and-braces rather than the only guard.
        let workflow = session.workflowController(forRunID: manifest.id)
        ScrollView {
            VStack(alignment: .leading, spacing: RafuMetrics.space3) {
                headerCard
                recoverySection
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
                                workflow?.revealLiveTerminal(stepIndex: row.index, in: session)
                            },
                            approve: { Task { await workflow?.approveGate() } },
                            revise: { workflow?.reviseArtifact(in: session) },
                            retry: { Task { await workflow?.retryFailedStep() } }
                        )
                    }
                }
                if !notes.isEmpty {
                    ConductorEnsembleNotesSection(notes: notes)
                }
                if isActiveRun, manifest.gate?.kind == .merge, let workflow {
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
        .task(id: manifest.id) {
            guard let rootURL = session.rootURL else {
                notes = []
                return
            }
            notes =
                (try? await ConductorEnsembleNoteStore(
                    workspaceRoot: rootURL,
                    eventCenter: .shared
                ).read(runID: manifest.id)) ?? []
        }
    }

    /// C7 recovery: an interrupted run states plainly that its process was not
    /// restored, and offers the three explicit verbs. There is deliberately no
    /// generic "Resume" — nothing is resurrected (ADR 0004/0014).
    @ViewBuilder
    private var recoverySection: some View {
        let interruptedIndex = manifest.steps.firstIndex { $0.status == .interrupted }
        if let interruptedIndex {
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                Label(
                    manifest.recoveryNote
                        ?? "The app closed while this step was running. Its process was not restored.",
                    systemImage: "bolt.horizontal.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(theme.palette.textPrimary)
                ConductorAdaptiveRow(spacing: 8) {
                    Button("Retry Step") {
                        guard let workflow = session.adoptInterruptedRun(manifest.id) else {
                            return
                        }
                        Task { await workflow.retryInterruptedStep(interruptedIndex) }
                    }
                    .buttonStyle(RafuProminentButtonStyle())
                    .accessibilityHint("Starts a fresh attempt for the interrupted step")
                    Button("Abort") {
                        session.adoptInterruptedRun(manifest.id)?.abortInterruptedRun()
                    }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .accessibilityHint("Marks this run aborted; evidence and worktree are kept")
                    if !manifest.worktreeBranch.isEmpty {
                        Button("Keep Worktree") {
                            session.adoptInterruptedRun(manifest.id)?.keepInterruptedWorktree()
                        }
                        .buttonStyle(RafuSecondaryButtonStyle())
                        .accessibilityHint("Closes the run and leaves its branch for manual work")
                    }
                }
            }
            .padding(RafuMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.cardBackground)
            .clipShape(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Interrupted run recovery")
        } else if let note = manifest.recoveryNote {
            // e.g. a worktree removed outside Rafu: history-only, no verbs.
            Label(note, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: RafuMetrics.space3) {
                headerIdentity
                Spacer(minLength: RafuMetrics.space3)
                headerActions
            }
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                headerIdentity
                headerActions
            }
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.cardBackground)
        .overlay(alignment: .bottom) {
            Divider().overlay(theme.palette.borderSubtle)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ensemble run summary")
    }

    private var headerIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            ConductorAdaptiveRow(spacing: RafuMetrics.space2) {
                Image(systemName: WorkspaceNavigatorMode.runs.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.info)
                    .accessibilityHidden(true)
                Text(manifest.workflowName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                RafuChip(
                    text: manifest.worktreeBranch.isEmpty
                        ? "Main workspace" : manifest.worktreeBranch
                )
                .accessibilityLabel(
                    manifest.worktreeBranch.isEmpty
                        ? "Main workspace" : "Worktree branch \(manifest.worktreeBranch)")
            }
            // Whole-run totals, absent entirely when nothing was metered.
            let runUsage = ConductorRunPresentation.runUsageLines(for: manifest)
            if !runUsage.isEmpty {
                Text("Run usage: \(runUsage.joined(separator: "  •  "))")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityLabel("Run usage \(runUsage.joined(separator: ", "))")
            }
        }
    }

    private var headerActions: some View {
        ConductorAdaptiveRow(spacing: RafuMetrics.space2) {
            RafuChip(text: String(manifest.baseCommit.prefix(8)), monospacedDigit: true)
                .accessibilityLabel("Base commit \(manifest.baseCommit.prefix(8))")
            if isActiveRun, let workflow = session.workflowController(forRunID: manifest.id),
                workflow.isInFlight
            {
                Button("Abort Run", systemImage: "xmark.circle", role: .destructive) {
                    workflow.abort()
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                .accessibilityHint(
                    "Stops the active process and parks this Ensemble run as aborted")
            }
        }
    }

    private var stepRows: [ConductorStepRowModel] {
        var liveIndex: Int?
        if isActiveRun, let state = session.workflowController(forRunID: manifest.id)?.state {
            liveIndex = ConductorRunPresentation.liveStepIndex(in: state)
        }
        return ConductorRunPresentation.stepRows(for: manifest, liveStepIndex: liveIndex)
    }

    private var failedStepIndex: Int? {
        guard isActiveRun,
            case .failed(let index, _) = session.workflowController(forRunID: manifest.id)?.state
        else { return nil }
        return index
    }
}

private struct ConductorEnsembleNotesSection: View {
    @Environment(\.rafuTheme) private var theme
    let notes: [ConductorEnsembleNoteStore.Note]

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            Text("Notes")
                .font(.headline)
                .foregroundStyle(theme.palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                    Text(note.at, style: .relative)
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                    Text(note.text)
                        .font(.callout)
                        .foregroundStyle(theme.palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Note \(note.text)")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ensemble run notes")
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    stepIdentity
                    Spacer(minLength: 8)
                    stepStatus
                }
                VStack(alignment: .leading, spacing: 4) {
                    stepIdentity
                    stepStatus
                }
            }
            ConductorAdaptiveRow(spacing: 6) {
                RafuChip(text: row.providerLabel, foreground: theme.palette.textSecondary)
                    .accessibilityLabel("Provider \(row.providerLabel)")
                RafuChip(text: row.modelLabel, foreground: theme.palette.textSecondary)
                    .accessibilityLabel("Model \(row.modelLabel)")
                if let durationLabel = row.durationLabel {
                    RafuChip(text: durationLabel, monospacedDigit: true)
                        .accessibilityLabel("Duration \(durationLabel)")
                }
                if let attemptLabel = row.attemptLabel {
                    RafuChip(text: attemptLabel)
                }
            }
            // Shown only when metering resolved an honest delta; a step with
            // no data renders nothing rather than "0%" (C7).
            if !row.usageLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(row.usageLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(theme.palette.textMuted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Usage \(row.usageLines.joined(separator: ", "))")
            }
            ConductorAdaptiveRow(spacing: 8) {
                Button("Open Artifact", action: openArtifact)
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .disabled(!row.canOpenArtifact)
                    .accessibilityHint("Opens this step's handoff artifact")
                if row.hasLiveTerminal {
                    Button("Reveal Terminal", action: revealTerminal)
                        .buttonStyle(RafuSecondaryButtonStyle())
                        .accessibilityHint("Reveals this step's active terminal")
                }
                if isActiveRun, row.isGateReady {
                    Button("Approve", action: approve)
                        .buttonStyle(RafuProminentButtonStyle())
                        .accessibilityHint("Approves this gate and starts the next step")
                    Button("Revise", action: revise)
                        .buttonStyle(RafuSecondaryButtonStyle())
                        .accessibilityHint("Opens the artifact for revision")
                }
                if isActiveRun, isFailedStep {
                    Button("Retry Step", action: retry)
                        .buttonStyle(RafuProminentButtonStyle())
                        .accessibilityHint("Starts a new attempt for this failed step")
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
        // Keep the card as a labelled rotor group, but preserve every
        // embedded Button as an individually reachable child.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(row.index + 1), \(row.agentName), \(row.statusLabel)")
    }

    private var stepIdentity: some View {
        HStack(spacing: 8) {
            Text("Step \(row.index + 1)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.palette.textMuted)
            Text(row.agentName)
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var stepStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: row.statusSymbol)
                .foregroundStyle(statusTint)
                .accessibilityHidden(true)
            Text(row.statusLabel)
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(row.statusLabel)")
    }

    private var statusTint: Color {
        // Switches on the semantic `status` (advisor D8), never
        // `statusSymbol`'s string — symbols stay pure presentation output.
        switch row.status {
        case .failed: theme.palette.gitDeleted
        case .awaitingGate, .interrupted: theme.palette.accent
        case .completed: theme.palette.gitAdded
        case .pending, .running, .aborted: theme.palette.textSecondary
        }
    }
}

/// Uses a horizontal row when its contents fit and a leading-aligned column
/// otherwise. This keeps chips and verbs reachable under enlarged text or a
/// narrow canvas without adding scrolling to action groups.
private struct ConductorAdaptiveRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                content
            }
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .accessibilityAddTraits(.isHeader)
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
                        .accessibilityLabel(
                            "Open diff for \(file.path), "
                                + (file.isUntracked ? "untracked file" : "modified file")
                        )
                        .accessibilityHint("Opens this worktree change in the editor")
                    }
                }
            }
            ConductorAdaptiveRow(spacing: 8) {
                Button("Apply to Workspace", action: apply)
                    .buttonStyle(RafuProminentButtonStyle())
                    .disabled(isResolving || hasApplied)
                    .accessibilityHint("Applies the reviewed worktree changes to the workspace")
                Button("Keep Worktree", action: keep)
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .disabled(isResolving)
                    .accessibilityHint("Leaves the run worktree and branch intact")
                Button("Discard…", role: .destructive) {
                    isDiscardConfirmationPresented = true
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                .disabled(isResolving)
                .accessibilityHint("Opens a confirmation before removing the run worktree")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Merge gate")
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
