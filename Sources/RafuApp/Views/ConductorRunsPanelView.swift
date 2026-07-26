import AppKit
import RafuCore
import SwiftUI

private enum ConductorRunsPanelSection: String, CaseIterable, Identifiable {
    case runs
    case workflows
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runs: "Runs"
        case .workflows: "Workflows"
        case .activity: "Activity"
        }
    }
}

/// `.runs` navigator panel: C5 run history plus C6's file-backed workflow
/// library in one segmented view.
///
/// The outer `.frame(maxWidth/maxHeight: .infinity, alignment: .top)` and
/// each empty state's own `.frame(maxWidth/maxHeight: .infinity)` are
/// load-bearing (AGENTS.md panel top-pinning rule): without them a
/// short/empty list floats the header to the vertical middle instead of
/// pinning it to the top.
struct ConductorRunsPanelView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme
    @State private var section = ConductorRunsPanelSection.runs
    @State private var libraryModel = ConductorWorkflowLibraryModel()
    @State private var activityEvents: [EnsembleEvent] = []

    var body: some View {
        @Bindable var controller = session.conductorRunController

        // Derived ONCE per body evaluation, mirroring
        // `WorkspaceTerminalsPanelView`'s own comment: recomputing per row
        // would be quadratic, and this panel expects only a handful of runs.
        let rows = session.conductorRuns.map { manifest in
            ConductorRunPresentation.runRow(
                for: manifest, liveState: liveState(for: manifest.id))
        }
        let attributionByRunID = Dictionary(
            uniqueKeysWithValues: session.conductorRuns.compactMap { manifest in
                startedByLabel(for: manifest).map { (manifest.id, $0) }
            })
        let active = rows.filter(\.isLive) + rows.filter { !$0.isLive && isUnresolved($0) }
        let history = rows.filter { !$0.isLive && !isUnresolved($0) }

        VStack(spacing: 0) {
            header
            Picker("Ensemble Section", selection: $section) {
                ForEach(ConductorRunsPanelSection.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, RafuMetrics.space3)
            .padding(.vertical, RafuMetrics.space2)

            switch section {
            case .runs:
                runsContent(
                    controller: controller,
                    rows: rows,
                    active: active,
                    history: history,
                    attributionByRunID: attributionByRunID)
            case .activity:
                activityContent
            case .workflows:
                workflowsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.rootURL?.standardizedFileURL) {
            await controller.attachAndReload(workspaceRoot: session.rootURL)
            await libraryModel.load(workspaceRoot: session.rootURL)
        }
        .task(id: activitySubscriptionID) {
            await observeActivity()
        }
        .sheet(item: $controller.newRunPresentation) { _ in
            ConductorNewRunSheet(session: session)
        }
        .confirmationDialog(
            "Replace existing definition files?",
            isPresented: pendingReplacementPresented,
            titleVisibility: .visible
        ) {
            if let pending = libraryModel.pendingReplacement {
                Button("Replace \(pending.conflicts.count) Existing File(s)", role: .destructive) {
                    Task {
                        await libraryModel.instantiate(
                            templateID: pending.templateID,
                            scope: pending.scope,
                            replaceConfirmed: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                libraryModel.clearPendingReplacement()
            }
        } message: {
            Text("Rafu will replace only the listed template destinations after this confirmation.")
        }
    }

    /// Cap-aware, not busy-aware: C6 allows several pipelines per window, so
    /// this only closes once `activeLimit` is reached.
    private var canStartNewRun: Bool {
        session.canStartConductorWorkflowRun
    }

    private var header: some View {
        RafuCardHeaderRow {
            HStack(spacing: 6) {
                Image(systemName: WorkspaceNavigatorMode.runs.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                Text("Ensemble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
            }
        } trailing: {
            HStack(spacing: 4) {
                Button("Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                    session.showConductorGraph()
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .help("Show Ensemble Graph")
                .disabled(session.rootURL == nil)
                if section == .workflows {
                    Menu("New from Template", systemImage: "doc.badge.plus") {
                        ForEach(ConductorBundledTemplateCatalog.templates) { template in
                            Menu(template.displayName) {
                                Button("Repository") {
                                    instantiate(template: template, scope: .repository)
                                }
                                Button("User") {
                                    instantiate(template: template, scope: .userGlobal)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("New from Template")
                    .disabled(libraryModel.isMutating || session.rootURL == nil)
                }
                Button("New Ensemble…", systemImage: "circle.hexagongrid") {
                    session.presentEnsembleStartSheet()
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .help("New Ensemble…")
                .disabled(session.rootURL == nil)
                Button("New Run…", systemImage: "plus") {
                    session.conductorRunController.presentNewRun()
                }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .help("New Run…")
                .disabled(!canStartNewRun)
            }
        }
    }

    @ViewBuilder
    private func runsContent(
        controller: ConductorRunController,
        rows: [ConductorRunRowModel],
        active: [ConductorRunRowModel],
        history: [ConductorRunRowModel],
        attributionByRunID: [String: String]
    ) -> some View {
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
                                row: row,
                                attribution: attributionByRunID[row.id],
                                reveal: { revealLiveTerminal(row.id) }
                            )
                            .tag(row.id)
                        }
                    }
                }
                if !history.isEmpty {
                    Section("History") {
                        ForEach(history) { row in
                            ConductorRunRowView(
                                row: row,
                                attribution: attributionByRunID[row.id],
                                reveal: nil
                            )
                            .tag(row.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        let manifestsByID = Dictionary(
            uniqueKeysWithValues: session.conductorRuns.map { ($0.id, $0) })
        if activityEvents.isEmpty {
            ContentUnavailableView {
                Label("No Run Activity", systemImage: "waveform.path.ecg")
            } description: {
                Text("Bounded Ensemble lifecycle events appear here while this workspace is open.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(activityEvents, id: \.cursor) { event in
                let manifest = manifestsByID[event.runID]
                ConductorActivityRow(
                    event: event,
                    manifest: manifest,
                    provider: provider(for: event, manifest: manifest),
                    openRun: manifest.map { manifest in
                        { session.showConductorRunDetail(manifest.id) }
                    })
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var workflowsContent: some View {
        if libraryModel.isLoading {
            ProgressView("Reading workflow files…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = libraryModel.errorMessage, libraryModel.workflows.isEmpty {
            ContentUnavailableView {
                Label("Unable to Load Workflows", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    Task { await libraryModel.load(workspaceRoot: session.rootURL) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if libraryModel.workflows.isEmpty {
            ContentUnavailableView {
                Label("No Workflows Yet", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Create an Ensemble workflow from a bundled template or add a Markdown file.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let error = libraryModel.errorMessage {
                    libraryMessage(error, systemImage: "exclamationmark.triangle", isError: true)
                } else if let message = libraryModel.operationMessage {
                    libraryMessage(message, systemImage: "checkmark.circle", isError: false)
                }
                List {
                    ForEach(ConductorDefinitionScope.allCases, id: \.rawValue) { scope in
                        let scoped = libraryModel.workflows.filter { $0.scope == scope }
                        if !scoped.isEmpty {
                            Section(scope.displayName) {
                                ForEach(scoped) { workflow in
                                    ConductorWorkflowLibraryRow(
                                        workflow: workflow,
                                        isMutating: libraryModel.isMutating,
                                        open: { openDefinition(workflow) },
                                        duplicate: {
                                            Task { _ = await libraryModel.duplicate(workflow) }
                                        },
                                        reveal: { revealInFinder(workflow.fileURL) })
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func libraryMessage(
        _ message: String,
        systemImage: String,
        isError: Bool
    ) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(isError ? theme.palette.error : theme.palette.textSecondary)
            .padding(.horizontal, RafuMetrics.space3)
            .padding(.vertical, RafuMetrics.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pendingReplacementPresented: Binding<Bool> {
        Binding(
            get: { libraryModel.pendingReplacement != nil },
            set: { presented in
                if !presented {
                    libraryModel.clearPendingReplacement()
                }
            })
    }

    private func instantiate(
        template: ConductorBundledTemplate,
        scope: ConductorDefinitionScope
    ) {
        Task {
            await libraryModel.instantiate(templateID: template.id, scope: scope)
        }
    }

    private func openDefinition(_ workflow: ConductorLibraryWorkflow) {
        let relativePath: String
        if let root = session.rootURL?.standardizedFileURL,
            workflow.fileURL.standardizedFileURL.path.hasPrefix(root.path + "/")
        {
            relativePath = String(
                workflow.fileURL.standardizedFileURL.path.dropFirst(root.path.count + 1))
        } else {
            relativePath = workflow.fileURL.path
        }
        session.open(
            WorkspaceFileNode(
                url: workflow.fileURL,
                relativePath: relativePath,
                isDirectory: false))
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func observeActivity() async {
        guard session.rootURL != nil else {
            activityEvents = []
            return
        }
        let center = ConductorEnsembleEventCenter.shared
        let knownRunIDs = Set(session.conductorRuns.map(\.id))
        activityEvents = Array(
            center.eventsSince(0)
                .filter { $0.kind != "heartbeat" && knownRunIDs.contains($0.runID) }
                .suffix(200)
                .reversed())
        let stream = center.subscribe()
        for await event in stream {
            guard !Task.isCancelled else { return }
            guard event.kind != "heartbeat",
                session.conductorRuns.contains(where: { $0.id == event.runID })
            else { continue }
            activityEvents.insert(event, at: 0)
            if activityEvents.count > 200 {
                activityEvents.removeLast(activityEvents.count - 200)
            }
        }
    }

    private var activitySubscriptionID: ConductorActivitySubscriptionID {
        ConductorActivitySubscriptionID(
            rootURL: session.rootURL?.standardizedFileURL,
            runIDs: session.conductorRuns.map(\.id).sorted())
    }

    private func provider(
        for event: EnsembleEvent,
        manifest: ConductorRunManifest?
    ) -> ConductorCLIID? {
        guard let manifest else { return nil }
        if let index = event.stepIndex, manifest.steps.indices.contains(index) {
            return manifest.steps[index].binding.provider
        }
        return manifest.steps.first?.binding.provider
    }

    private func startedByLabel(for manifest: ConductorRunManifest) -> String? {
        guard let startedBy = manifest.startedBy else { return nil }
        if let coordinator = session.conductorCoordinatorSessions.first(where: {
            $0.id == startedBy
        }) {
            let label = coordinator.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                return String(label.prefix(28))
            }
        }
        return String(startedBy.prefix(12))
    }

    private var runSelection: Binding<String?> {
        Binding(
            get: { session.selectedConductorRunID },
            set: { newValue in
                guard let newValue else { return }
                session.showConductorRunDetail(newValue)
            })
    }

    /// Live state for `runID` ONLY when some live engine in this window still
    /// owns it — any of C6's concurrent controllers, or the singular one. A
    /// historical run (or one the C1 single-role controller drove) gets no
    /// live-state overlay, per `ConductorRunPresentation.runRow`'s contract.
    private func liveState(for runID: String) -> ConductorWorkflowState? {
        guard let controller = session.workflowController(forRunID: runID),
            controller.manifest?.id == runID
        else { return nil }
        return controller.state
    }

    /// History vs Active for a run this window did NOT start (or restarted
    /// since): an open gate, or a semantic status of pending/running/
    /// awaiting-gate/failed, keeps it in Active — a failed run is exactly
    /// as actionable (Retry) as a running one; only completed/aborted with
    /// no open gate reads as History. Switches on the row's semantic
    /// `status` (advisor D8), never on `statusSymbol`'s string.
    private func isUnresolved(_ row: ConductorRunRowModel) -> Bool {
        if row.gateBadge != nil { return true }
        switch row.status {
        // Interrupted belongs in Active: it is exactly as actionable as a
        // failure (Retry / Abort / Keep worktree).
        case .pending, .running, .awaitingGate, .failed, .interrupted:
            return true
        case .completed, .aborted:
            return false
        }
    }

    private func revealLiveTerminal(_ runID: String) {
        if let controller = session.workflowController(forRunID: runID),
            controller.manifest?.id == runID,
            let index = ConductorRunPresentation.liveStepIndex(in: controller.state)
        {
            controller.revealLiveTerminal(stepIndex: index, in: session)
        } else {
            session.conductorRunController.revealLiveTerminal(for: runID, in: session)
        }
    }
}

private struct ConductorActivitySubscriptionID: Equatable {
    let rootURL: URL?
    let runIDs: [String]
}

private struct ConductorRunRowView: View {
    let row: ConductorRunRowModel
    let attribution: String?
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
                    if let attribution {
                        RafuChip(text: "via \(attribution)")
                            .accessibilityLabel("Started by \(attribution)")
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
        .accessibilityLabel(
            "\(row.title), \(row.statusLabel)\(attribution.map { ", started by \($0)" } ?? "")")
    }
}

private struct ConductorActivityRow: View {
    let event: EnsembleEvent
    let manifest: ConductorRunManifest?
    let provider: ConductorCLIID?
    let openRun: (() -> Void)?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let provider {
                    FileIconView(icon: ConductorCLIIcons.icon(for: provider), size: 14)
                        .help(provider.displayName)
                        .accessibilityLabel("Provider \(provider.displayName)")
                    Text(provider.displayName)
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(event.at, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)
            if let openRun {
                Button("Open Run", action: openRun)
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        let identity =
            event.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? manifest?.label?.nilIfEmpty
            ?? manifest?.workflowName.nilIfEmpty
            ?? String(event.runID.prefix(12))
        if let note = event.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return "\(identity): \(String(note.prefix(120)))"
        }
        if let state = event.state {
            return "\(identity) → \(state.activityLabel)"
        }
        return "\(identity) · \(String(event.kind.prefix(48)))"
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension EnsembleRunState {
    fileprivate var activityLabel: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .awaitingGate: "Awaiting gate"
        case .awaitingPlanGate: "Awaiting plan gate"
        case .awaitingMergeGate: "Awaiting merge gate"
        case .completed: "Completed"
        case .failed: "Failed"
        case .aborted: "Aborted"
        case .interrupted: "Interrupted"
        case .merged: "Merged"
        }
    }
}

private struct ConductorWorkflowLibraryRow: View {
    let workflow: ConductorLibraryWorkflow
    let isMutating: Bool
    let open: () -> Void
    let duplicate: () -> Void
    let reveal: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(
                    systemName: workflow.isLaunchable
                        ? "point.3.connected.trianglepath.dotted" : "exclamationmark.triangle"
                )
                .foregroundStyle(
                    workflow.isLaunchable ? theme.palette.textSecondary : theme.palette.error)
                Text(workflow.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if workflow.resolution == .overriddenByRepository {
                    RafuChip(text: workflow.resolution.label)
                }
                Spacer(minLength: 4)
                Button("Open", action: open)
                    .buttonStyle(RafuSecondaryButtonStyle())
                Menu("Workflow Actions", systemImage: "ellipsis") {
                    Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate)
                        .disabled(isMutating)
                    Button("Reveal in Finder", systemImage: "folder", action: reveal)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text(workflow.fileURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
                .lineLimit(1)
            ForEach(workflow.issues) { issue in
                Label(
                    issue.line.map { "Line \($0): \(issue.message)" } ?? issue.message,
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(theme.palette.error)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Open", action: open)
            Button("Duplicate", action: duplicate)
                .disabled(isMutating)
            Button("Reveal in Finder", action: reveal)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(workflow.displayName), \(workflow.scope.displayName), \(workflow.resolution.label)")
    }
}

private struct ConductorNewRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkspaceSession
    @State private var model = ConductorNewRunModel()
    @State private var workflowModel = ConductorWorkflowLaunchModel()
    @State private var taskPrompt = ""
    @State private var baseReference = "HEAD"
    @State private var isStartingWorkflow = false
    @State private var workflowStartError: String?
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

            if model.isLoading || (model.mode == .workflow && workflowModel.isLoading) {
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

            if let error = visibleError {
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
                            case .singleRole: await startSingleRole()
                            case .workflow: await startWorkflow()
                            }
                        if started { dismiss() }
                    }
                } label: {
                    if model.isStarting || isStartingWorkflow {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Run")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 520, minHeight: 420)
        .task(id: session.rootURL?.standardizedFileURL) {
            await model.load(workspaceRoot: session.rootURL)
            await workflowModel.load(workspaceRoot: session.rootURL)
            if !model.agents.isEmpty || !workflowModel.workflows.isEmpty {
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
                TextField("Task prompt", text: $taskPrompt, axis: .vertical)
                    .lineLimit(4...8)
                    .focused($promptFocused)
                TextField("Base reference", text: $baseReference)
                    .help("Branch, tag, or commit. Defaults to the current HEAD.")
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var workflowForm: some View {
        if workflowModel.workflows.isEmpty, workflowModel.errorMessage == nil {
            ContentUnavailableView {
                Label("No Workflow Files", systemImage: "list.bullet.rectangle")
            } description: {
                Text(
                    "Add a repository or user Ensemble workflow, or create one from the Workflows library."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Picker("Workflow file", selection: selectedWorkflowBinding) {
                    ForEach(workflowModel.workflows) { workflow in
                        Text(
                            "\(workflow.displayName) — \(workflow.scope.displayName) — \(workflow.fileURL.lastPathComponent)"
                        )
                        .tag(Optional(workflow.id))
                    }
                }
                TextField("Task prompt", text: $taskPrompt, axis: .vertical)
                    .lineLimit(4...8)
                    .focused($promptFocused)
                TextField("Base reference", text: $baseReference)
                    .help("Branch, tag, or commit. Defaults to the current HEAD.")
                if let workflow = workflowModel.selectedWorkflow {
                    if !workflow.issues.isEmpty {
                        Section("Fix Before Running") {
                            ForEach(workflow.issues) { issue in
                                Label(
                                    issue.line.map { "Line \($0): \(issue.message)" }
                                        ?? issue.message,
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    if !workflowModel.resolvedRoles.isEmpty {
                        Section("Steps and Model Overrides") {
                            ForEach(workflowModel.resolvedRoles) { role in
                                workflowStepRow(role)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func workflowStepRow(_ role: ConductorWorkflowLaunchRole) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(role.stepIndex + 1). \(role.step.agentName)")
                    .lineLimit(1)
                RafuChip(text: role.definition.provider.displayName)
                if role.step.gateAfter {
                    RafuChip(text: "gate")
                }
                Spacer()
            }
            TextField(
                "Model override",
                text: Binding(
                    get: { workflowModel.modelValue(for: role.stepIndex) },
                    set: { workflowModel.setModelValue($0, for: role.stepIndex) })
            )
            .help(modelHelp(for: role))
        }
    }

    private var selectedWorkflowBinding: Binding<String?> {
        Binding(
            get: { workflowModel.selectedWorkflowID },
            set: { newValue in
                guard let newValue else { return }
                workflowModel.selectWorkflow(id: newValue)
            })
    }

    private var canStart: Bool {
        guard !taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch model.mode {
        case .singleRole:
            return !model.isLoading && !model.isStarting && model.selectedAgent != nil
        case .workflow:
            guard
                !workflowModel.isLoading,
                !isStartingWorkflow,
                workflowModel.selectedWorkflow?.isLaunchable == true,
                let count = workflowModel.selectedWorkflow?.definition?.steps.count
            else { return false }
            return workflowModel.resolvedRoles.count == count
        }
    }

    private var visibleError: String? {
        workflowStartError
            ?? (model.mode == .workflow ? workflowModel.errorMessage : model.errorMessage)
    }

    private func modelHelp(for role: ConductorWorkflowLaunchRole) -> String {
        let choices = role.modelChoices.map(\.id)
        guard !choices.isEmpty else {
            return
                "Leave the file's value unchanged, clear it for the adapter default, or enter a model identifier."
        }
        return
            "Known models: \(choices.joined(separator: ", ")). You may also enter another identifier."
    }

    private func startSingleRole() async -> Bool {
        model.taskPrompt = taskPrompt
        model.baseReference = baseReference
        return await model.start(in: session)
    }

    private func startWorkflow() async -> Bool {
        guard !isStartingWorkflow else { return false }
        isStartingWorkflow = true
        workflowStartError = nil
        defer { isStartingWorkflow = false }

        workflowModel.taskPrompt = taskPrompt
        workflowModel.baseReference = baseReference
        do {
            let request = try workflowModel.makeRequest()
            // Free slots held by runs that already finished, so the cap counts
            // only genuinely active pipelines.
            session.conductorConcurrentRuns.removeFinishedRuns()
            let launcher = WorkspaceConductorRunLauncher(
                workspaceSession: session,
                runID: request.runID)
            // C6: the concurrent coordinator owns the run for its lifetime and
            // enforces the per-window cap, run-ID uniqueness, and distinct
            // worktrees — it throws a typed, user-readable refusal instead of
            // silently starting a colliding run.
            let controller = try await session.conductorConcurrentRuns.start(
                request,
                launcher: launcher)
            if case .failed(_, let reason) = controller.state {
                workflowStartError = reason
                return false
            }
            return controller.isInFlight
        } catch {
            workflowStartError =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not start the Ensemble workflow."
            return false
        }
    }
}
