import SwiftUI

/// `.runs` navigator panel (C5): active runs with per-step status and gate
/// badges, then history from `.rafu/runs`. Mirrors
/// `WorkspaceTerminalsPanelView`'s header/list/empty-state structure.
///
/// The outer `.frame(maxWidth/maxHeight: .infinity, alignment: .top)` and
/// each empty state's own `.frame(maxWidth/maxHeight: .infinity)` are
/// load-bearing (AGENTS.md panel top-pinning rule): without them a
/// short/empty list floats the header to the vertical middle instead of
/// pinning it to the top.
struct ConductorRunsPanelView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        @Bindable var controller = session.conductorRunController
        @Bindable var workflow = session.conductorWorkflowController

        // Derived ONCE per body evaluation, mirroring
        // `WorkspaceTerminalsPanelView`'s own comment: recomputing per row
        // would be quadratic, and this panel expects only a handful of runs.
        let rows = session.conductorRuns.map { manifest in
            ConductorRunPresentation.runRow(
                for: manifest, liveState: liveState(for: manifest.id))
        }
        let active = rows.filter(\.isLive) + rows.filter { !$0.isLive && isUnresolved($0) }
        let history = rows.filter { !$0.isLive && !isUnresolved($0) }

        VStack(spacing: 0) {
            header(count: rows.count)
            if let error = controller.runsLoadError {
                ContentUnavailableView {
                    Label("Unable to Load Runs", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task { await controller.reloadRuns() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Runs Yet", systemImage: WorkspaceNavigatorMode.runs.symbolName)
                } description: {
                    Text(
                        "Ensemble runs appear here once a run has been started. Rafu never starts one on its own."
                    )
                } actions: {
                    Button("New Run…", systemImage: "plus") {
                        controller.presentNewRun()
                    }
                    .disabled(!canStartNewRun)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: runSelection) {
                    if !active.isEmpty {
                        Section("Active") {
                            ForEach(active) { row in
                                ConductorRunRowView(
                                    row: row, reveal: { revealLiveTerminal(row.id) }
                                )
                                .tag(row.id)
                            }
                        }
                    }
                    if !history.isEmpty {
                        Section("History") {
                            ForEach(history) { row in
                                ConductorRunRowView(row: row, reveal: nil)
                                    .tag(row.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.rootURL?.standardizedFileURL) {
            await controller.attachAndReload(workspaceRoot: session.rootURL)
        }
        .sheet(item: $controller.newRunPresentation) { _ in
            ConductorNewRunSheet(session: session)
        }
    }

    private var canStartNewRun: Bool {
        session.conductorRunController.canStartNewRun
            && !session.conductorWorkflowController.isInFlight
    }

    private func header(count: Int) -> some View {
        RafuCardHeaderRow {
            HStack(spacing: 6) {
                Image(systemName: WorkspaceNavigatorMode.runs.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                Text("Runs (\(count))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
            }
        } trailing: {
            Button("New Run…", systemImage: "plus") {
                session.conductorRunController.presentNewRun()
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("New Run…")
            .disabled(!canStartNewRun)
        }
    }

    private var runSelection: Binding<String?> {
        Binding(
            get: { session.selectedConductorRunID },
            set: { newValue in
                guard let newValue else { return }
                session.showConductorRunDetail(newValue)
            })
    }

    /// Live state for `runID` ONLY when the workflow controller's current
    /// manifest matches it — a historical run (or one the C1 single-role
    /// controller drove) gets no live-state overlay, per
    /// `ConductorRunPresentation.runRow`'s contract.
    private func liveState(for runID: String) -> ConductorWorkflowState? {
        guard session.conductorWorkflowController.manifest?.id == runID else { return nil }
        return session.conductorWorkflowController.state
    }

    /// History vs Active for a run this window did NOT start (or restarted
    /// since): pending/running/awaiting-gate steps, or an open gate, keep it
    /// in Active; a run whose last recorded step is completed/failed/aborted
    /// with no open gate reads as History — retrying (if still possible) is
    /// still reachable by selecting it, independent of this grouping.
    private func isUnresolved(_ row: ConductorRunRowModel) -> Bool {
        row.gateBadge != nil || row.statusSymbol == "circle.dotted"
            || row.statusSymbol == "circle.fill"
    }

    private func revealLiveTerminal(_ runID: String) {
        if session.conductorWorkflowController.manifest?.id == runID,
            let index = ConductorRunPresentation.liveStepIndex(
                in: session.conductorWorkflowController.state)
        {
            session.conductorWorkflowController.revealLiveTerminal(stepIndex: index, in: session)
        } else {
            session.conductorRunController.revealLiveTerminal(for: runID, in: session)
        }
    }
}

private struct ConductorRunRowView: View {
    let row: ConductorRunRowModel
    /// `nil` when this run has no live terminal to reveal.
    let reveal: (() -> Void)?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: RafuMetrics.space3) {
            Image(systemName: row.statusSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    row.needsAttention ? theme.palette.accent : theme.palette.textSecondary
                )
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    if let gateBadge = row.gateBadge {
                        RafuChip(text: gateBadge, foreground: theme.palette.accent)
                    }
                }
                Text("\(row.subtitle) · \(row.statusLabel)")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let reveal {
                Button("Reveal Terminal", action: reveal)
                    .buttonStyle(RafuSecondaryButtonStyle())
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.statusLabel)")
    }
}

private struct ConductorNewRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkspaceSession
    @State private var model = ConductorNewRunModel()
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Ensemble Run")
                    .font(.title2.weight(.semibold))
                Text("Choose a role or workflow. Rafu starts nothing until you select Run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Mode", selection: $model.mode) {
                ForEach(ConductorNewRunMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.isLoading {
                ProgressView("Reading .rafu files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.mode {
                case .singleRole:
                    singleRoleForm
                case .workflow:
                    workflowForm
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Run error: \(error)")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        let started =
                            switch model.mode {
                            case .singleRole: await model.start(in: session)
                            case .workflow: await model.startWorkflow(in: session)
                            }
                        if started { dismiss() }
                    }
                } label: {
                    if model.isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Run")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 520, minHeight: 420)
        .task(id: session.rootURL?.standardizedFileURL) {
            await model.load(workspaceRoot: session.rootURL)
            if !model.agents.isEmpty {
                promptFocused = true
            }
        }
    }

    @ViewBuilder
    private var singleRoleForm: some View {
        if model.agents.isEmpty, model.errorMessage == nil {
            ContentUnavailableView {
                Label("No Agent Files", systemImage: "person.crop.rectangle.stack")
            } description: {
                Text("Add a Markdown role under .rafu/agents/ to start a run.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Picker("Agent file", selection: $model.selectedAgentID) {
                    ForEach(model.agents) { agent in
                        Text("\(agent.definition.name) — \(agent.relativePath)")
                            .tag(Optional(agent.id))
                    }
                }
                TextField("Task prompt", text: $model.taskPrompt, axis: .vertical)
                    .lineLimit(4...8)
                    .focused($promptFocused)
                TextField("Base reference", text: $model.baseReference)
                    .help("Branch, tag, or commit. Defaults to the current HEAD.")
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var workflowForm: some View {
        if model.workflows.isEmpty, model.errorMessage == nil {
            ContentUnavailableView {
                Label("No Workflow Files", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Add a Markdown pipeline under .rafu/workflows/ to start a run.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Picker("Workflow file", selection: $model.selectedWorkflowID) {
                    ForEach(model.workflows) { workflow in
                        Text("\(workflow.definition.name) — \(workflow.relativePath)")
                            .tag(Optional(workflow.id))
                    }
                }
                TextField("Task prompt", text: $model.taskPrompt, axis: .vertical)
                    .lineLimit(4...8)
                    .focused($promptFocused)
                TextField("Base reference", text: $model.baseReference)
                    .help("Branch, tag, or commit. Defaults to the current HEAD.")
                if let workflow = model.selectedWorkflow {
                    Section("Resolved Steps") {
                        workflowStepPreview(for: workflow)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func workflowStepPreview(for workflow: ConductorWorkflowFile) -> some View {
        switch model.resolvedWorkflowSteps {
        case .success(let roles):
            ForEach(Array(zip(workflow.definition.steps, roles)), id: \.0.agentName) {
                step, role in
                HStack(spacing: 6) {
                    Text(step.agentName).lineLimit(1)
                    RafuChip(text: role.provider.displayName)
                    if step.gateAfter {
                        RafuChip(text: "gate")
                    }
                    Spacer()
                }
            }
        case .failure(let error):
            Label(
                error.errorDescription ?? "This workflow could not be resolved.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}
