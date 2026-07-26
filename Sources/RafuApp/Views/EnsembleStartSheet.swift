import AppKit
import SwiftUI

/// The three doors into a new Ensemble (C8-coordinator-ux.md "Three doors,
/// one default"): describe a goal in plain language (guided, the default —
/// no prior knowledge of agent/workflow files required), instantiate a
/// bundled template, or launch an existing workflow (expert). `Hashable` so
/// `RafuSegmentedPicker` can bind to it directly.
enum EnsembleDoor: String, CaseIterable, Hashable, Identifiable {
    case guided
    case template
    case expert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guided: "Describe a Goal"
        case .template: "From a Template"
        case .expert: "Existing Workflow"
        }
    }
}

/// The coordinator grant's wall-clock backstop (C8-coordinator-ux.md "The
/// consent model"). `.none` means no wall-clock ceiling — the run/usage caps
/// still apply.
enum EnsembleGrantDeadline: String, CaseIterable, Hashable, Identifiable {
    case none
    case oneHour
    case fourHours
    case eightHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No deadline"
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .eightHours: "8 hours"
        }
    }

    func date(from now: Date) -> Date? {
        switch self {
        case .none: nil
        case .oneHour: now.addingTimeInterval(3600)
        case .fourHours: now.addingTimeInterval(4 * 3600)
        case .eightHours: now.addingTimeInterval(8 * 3600)
        }
    }
}

/// Door 1 (guided) model: probes the adapter registry through
/// `AgentTerminalLaunchService.options()` — the SAME resolve+authStatus
/// mapping the Agent Terminal picker uses, so Door 1's CLI gating can never
/// drift from that picker's (one policy, read twice). Never touches the
/// filesystem or a CLI from `init`; `probeCLIs(workspaceRoot:)` is the one
/// async entry point, called only from the sheet's `.task`.
@MainActor
@Observable
final class EnsembleStartModel {
    typealias Clock = @MainActor () -> Date
    typealias Launch =
        @MainActor (
            _ provider: ConductorCLIID,
            _ model: String?,
            _ goal: String,
            _ grant: ConductorEnsembleGrant,
            _ session: WorkspaceSession
        ) async throws -> ConductorCoordinatorSession

    var door: EnsembleDoor = .guided

    private(set) var cliOptions: [AgentTerminalOption] = []
    var selectedProvider: ConductorCLIID?
    var model = ""
    var goal = ""

    var maxConcurrent = 3
    var maxTotal = 12
    var allowedProviders: Set<ConductorCLIID> = []
    var deadlineChoice: EnsembleGrantDeadline = .none

    private(set) var isStarting = false
    var errorMessage: String?

    /// Non-`nil` once the coordinator has actually launched — the signal the
    /// sheet uses to show the copyable-goal confirmation row. Every current
    /// CLI's launch shape has no initial-prompt argument
    /// (`AgentTerminalLaunchShape.arguments(model:)` only ever appends a
    /// model flag), so this row is unconditional for Door 1, never a
    /// per-CLI capability check.
    private(set) var postLaunchGoalToPaste: String?

    @ObservationIgnored
    private let adapters: [any ConductorCLIAdapter]
    @ObservationIgnored
    private let defaultModelStore: ConductorDefaultModelStore
    @ObservationIgnored
    private let clock: Clock
    @ObservationIgnored
    private let launch: Launch

    init(
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        defaultModelStore: ConductorDefaultModelStore = ConductorDefaultModelStore(),
        clock: @escaping Clock = Date.init,
        launch: @escaping Launch = { provider, model, goal, grant, session in
            try await ConductorCoordinatorLauncher().start(
                provider: provider, model: model, goal: goal, grant: grant, in: session)
        }
    ) {
        self.adapters = adapters
        self.defaultModelStore = defaultModelStore
        self.clock = clock
        self.launch = launch
    }

    /// Seeds the ready-CLI set into `allowedProviders` and the selected
    /// provider on first load only, so a later re-probe (workspace switch)
    /// never silently discards a choice the user already made.
    func probeCLIs(workspaceRoot: URL?) async {
        guard let workspaceRoot else {
            cliOptions = []
            return
        }
        let loaded = await AgentTerminalLaunchService(
            workspaceRoot: workspaceRoot,
            adapters: adapters,
            defaultModelStore: defaultModelStore
        ).options()
        guard !Task.isCancelled else { return }
        cliOptions = loaded
        let readyIDs = loaded.filter(\.isReady).map(\.id)
        if allowedProviders.isEmpty {
            allowedProviders = Set(readyIDs)
        }
        if let selectedProvider, isEnabled(selectedProvider) {
            // Keep the user's (or a prior probe's) choice — the provider
            // did not change, so its model field is left untouched.
        } else if let firstReady = readyIDs.first {
            selectProvider(firstReady)
        } else {
            selectedProvider = nil
        }
    }

    func isEnabled(_ id: ConductorCLIID) -> Bool {
        cliOptions.first { $0.id == id }?.isReady ?? false
    }

    /// Selects `id` as the coordinator provider and resets the model field
    /// to ITS default — never leaves a previously selected CLI's model
    /// string in place for a different vendor (matches
    /// `AgentTerminalSheet.select(_:)`'s own unconditional reset). Without
    /// this, switching CLIs after typing/prefilling a model launches one
    /// vendor's model string on another vendor's CLI.
    func selectProvider(_ id: ConductorCLIID) {
        selectedProvider = id
        model = cliOptions.first(where: { $0.id == id })?.defaultModel ?? ""
    }

    /// `nil` only for a ready CLI. The not-authenticated case reproduces the
    /// adapter's own hint text verbatim (never rewritten); the not-installed
    /// case is reworded for THIS sheet's action rather than reusing the
    /// Agent Terminal picker's wording, which names a different feature.
    func disableReason(_ id: ConductorCLIID) -> String? {
        guard let option = cliOptions.first(where: { $0.id == id }) else { return nil }
        switch option.availability {
        case .ready:
            return nil
        case .notInstalled:
            return "Not installed — install this CLI to use it as a coordinator."
        case .notAuthenticated(let hint):
            return hint
        }
    }

    /// An empty `allowedProviders` set would still let the coordinator
    /// launch, but `ConductorEnsembleTokenStore.enforce` refuses EVERY
    /// child run with `.providerNotAllowed` (exit 77) — the coordinator
    /// would look healthy on the graph while every run silently dies inside
    /// the CLI's own output. The grant is the consent surface, so this is
    /// required here, not just left to the runtime enforcement.
    var canStartGuided: Bool {
        guard let selectedProvider, isEnabled(selectedProvider) else { return false }
        guard !allowedProviders.isEmpty else { return false }
        return !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `windowCap` is `session.conductorConcurrentRuns.activeLimit` — the
    /// same per-window cap C6's concurrent-run coordinator enforces, so the
    /// grant's concurrency ceiling can never promise more than this window
    /// can actually run.
    func makeGrant(windowCap: Int) -> ConductorEnsembleGrant {
        let cap = max(1, windowCap)
        return ConductorEnsembleGrant(
            maxConcurrentChildRuns: min(max(1, maxConcurrent), cap),
            maxTotalChildRuns: max(1, maxTotal),
            allowedProviders: Array(allowedProviders),
            usageCeilingPercentPoints: nil,
            deadline: deadlineChoice.date(from: clock())
        )
    }

    /// Launches the coordinator via the injected `launch` closure (real
    /// `ConductorCoordinatorLauncher.start` by default). On success the sheet
    /// STAYS open showing `postLaunchGoalToPaste` — `finishAndShowGraph(in:)`
    /// is the explicit "Done" verb that actually lands the user on the graph
    /// canvas, so the copyable goal is never a toast the user might miss. On
    /// failure nothing is registered and `errorMessage` is set; the sheet
    /// stays open with the form untouched.
    @discardableResult
    func start(in session: WorkspaceSession) async -> Bool {
        guard let selectedProvider, isEnabled(selectedProvider) else { return false }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return false }

        isStarting = true
        errorMessage = nil
        defer { isStarting = false }

        let grant = makeGrant(windowCap: session.conductorConcurrentRuns.activeLimit)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await launch(
                selectedProvider,
                trimmedModel.isEmpty ? nil : trimmedModel,
                trimmedGoal,
                grant,
                session)
            postLaunchGoalToPaste = trimmedGoal
            return true
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not start the Ensemble coordinator."
            return false
        }
    }

    /// The "Done" verb after the post-launch confirmation row.
    func finishAndShowGraph(in session: WorkspaceSession) {
        session.showConductorGraph()
        session.ensembleStartSheetPresented = false
        postLaunchGoalToPaste = nil
    }
}

/// "New Ensemble…" (⌘⇧E / Rafu menu / palette / Runs-panel button): the one
/// cold-start sheet a user needs, ever. Structure copied from
/// `GitHubPublishSheet` (header, grouped form, cancel/default keyboard
/// shortcuts, fixed width, `RafuMetrics.sheetPadding`).
struct EnsembleStartSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession

    @State private var model = EnsembleStartModel()

    @State private var templateLibraryModel = ConductorWorkflowLibraryModel()
    @State private var selectedTemplateID: String? = ConductorBundledTemplateCatalog.templates
        .first?.id

    @State private var workflowLaunchModel = ConductorWorkflowLaunchModel()
    @State private var expertTaskPrompt = ""
    @State private var expertBaseReference = "HEAD"
    @State private var isStartingExpertWorkflow = false
    @State private var expertWorkflowStartError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "circle.hexagongrid",
                title: "New Ensemble",
                subtitle: "Describe a goal, start from a template, or launch an existing workflow."
            )

            RafuSegmentedPicker(items: EnsembleDoor.allCases, selection: $model.door) { $0.title }

            Group {
                if isShowingLaunchConfirmation {
                    launchConfirmation
                } else {
                    switch model.door {
                    case .guided:
                        guidedDoor
                    case .template:
                        templateDoor
                    case .expert:
                        expertDoor
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let doorErrorMessage {
                Label(doorErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(theme.palette.error)
                    .accessibilityLabel("Cannot start: \(doorErrorMessage)")
            }

            footer
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 480)
        .task(id: session.rootURL?.standardizedFileURL) {
            async let cliProbe: Void = model.probeCLIs(workspaceRoot: session.rootURL)
            async let templateLoad: Void = templateLibraryModel.load(
                workspaceRoot: session.rootURL)
            async let workflowLoad: Void = workflowLaunchModel.load(workspaceRoot: session.rootURL)
            _ = await (cliProbe, templateLoad, workflowLoad)
        }
        .confirmationDialog(
            "Replace existing definition files?",
            isPresented: pendingReplacementPresented,
            titleVisibility: .visible
        ) {
            if let pending = templateLibraryModel.pendingReplacement {
                Button("Replace \(pending.conflicts.count) Existing File(s)", role: .destructive) {
                    let templateID = pending.templateID
                    Task {
                        await templateLibraryModel.instantiate(
                            templateID: templateID,
                            scope: pending.scope,
                            replaceConfirmed: true)
                        openInstantiatedWorkflowIfReady(templateID: templateID)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                templateLibraryModel.clearPendingReplacement()
            }
        } message: {
            Text("Rafu will replace only the listed template destinations after this confirmation.")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !isShowingLaunchConfirmation {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Button(primaryTitle) { primaryAction() }
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canStartPrimary)
        }
    }

    private var isBusy: Bool {
        model.isStarting || templateLibraryModel.isMutating || isStartingExpertWorkflow
    }

    private var isShowingLaunchConfirmation: Bool {
        model.door == .guided && model.postLaunchGoalToPaste != nil
    }

    private var canStartPrimary: Bool {
        if isShowingLaunchConfirmation { return true }
        switch model.door {
        case .guided:
            return model.canStartGuided && !model.isStarting
        case .template:
            return selectedTemplateID != nil && session.rootURL != nil
                && !templateLibraryModel.isMutating
        case .expert:
            return session.canStartConductorWorkflowRun && expertCanStart
        }
    }

    private var primaryTitle: String {
        if isShowingLaunchConfirmation { return "Done" }
        switch model.door {
        case .guided: return "Start Coordinator"
        case .template: return "Add to This Repository"
        case .expert: return "Start Run"
        }
    }

    private func primaryAction() {
        if isShowingLaunchConfirmation {
            model.finishAndShowGraph(in: session)
            return
        }
        switch model.door {
        case .guided:
            Task { await model.start(in: session) }
        case .template:
            startTemplateDoor()
        case .expert:
            startExpertWorkflow()
        }
    }

    private var doorErrorMessage: String? {
        guard model.door == .guided, !isShowingLaunchConfirmation else { return nil }
        if let errorMessage = model.errorMessage { return errorMessage }
        // Surfaced near the Start button (text, not color alone) the moment
        // the grant's allowed set is empty — an empty set would silently
        // refuse every child run at the enforcement layer instead.
        if model.allowedProviders.isEmpty {
            return
                "Allow at least one CLI in the budget grant so the coordinator can start a child run."
        }
        return nil
    }

    // MARK: - Door 1: guided

    private var windowCap: Int {
        session.conductorConcurrentRuns.activeLimit
    }

    private var guidedDoor: some View {
        Form {
            Section("Coordinator") {
                if model.cliOptions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking installed CLIs…")
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.cliOptions) { option in
                            EnsembleCLIPickerRow(
                                option: option,
                                isSelected: model.selectedProvider == option.id,
                                reason: model.disableReason(option.id),
                                select: { selectProvider(option) }
                            )
                        }
                    }
                }
                TextField("Model (optional)", text: $model.model)
                    .disabled(model.selectedProvider == nil)
            }

            Section("Goal") {
                ZStack(alignment: .topLeading) {
                    if model.goal.isEmpty {
                        Text("What should the ensemble accomplish? Plain language.")
                            .foregroundStyle(theme.palette.textMuted)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.goal)
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                }
            }

            Section {
                Stepper(
                    "Max concurrent child runs: \(model.maxConcurrent)",
                    value: $model.maxConcurrent,
                    in: 1...max(1, min(3, windowCap))
                )
                Text("Capped at \(windowCap) per window.")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                Stepper(
                    "Max total child runs: \(model.maxTotal)",
                    value: $model.maxTotal,
                    in: 1...50
                )
                ForEach(model.cliOptions) { option in
                    Toggle(option.displayName, isOn: allowedBinding(option.id))
                        .disabled(!option.isReady)
                }
                Picker("Deadline", selection: $model.deadlineChoice) {
                    ForEach(EnsembleGrantDeadline.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } header: {
                Text("Budget grant")
            } footer: {
                // The consent model (C8-coordinator-ux.md): the grant is
                // always visible here, never buried in Settings. Usage
                // ceiling is deliberately absent from v1 UI — the grant type
                // supports it, but no per-provider usage editor exists yet.
                Text(
                    "The coordinator can start at most this many child runs and reach only the CLIs you allow."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func selectProvider(_ option: AgentTerminalOption) {
        guard option.isReady else { return }
        model.selectProvider(option.id)
    }

    private func allowedBinding(_ id: ConductorCLIID) -> Binding<Bool> {
        Binding(
            get: { model.allowedProviders.contains(id) },
            set: { isOn in
                if isOn {
                    model.allowedProviders.insert(id)
                } else {
                    model.allowedProviders.remove(id)
                }
            })
    }

    private var launchConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Coordinator Launched", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(theme.palette.textPrimary)
            Text(
                "This CLI has no way to accept an initial prompt automatically. Paste your goal into its terminal tab."
            )
            .font(.callout)
            .foregroundStyle(theme.palette.textSecondary)
            if let goal = model.postLaunchGoalToPaste {
                HStack(alignment: .top, spacing: 8) {
                    Text(goal)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(
                                cornerRadius: RafuMetrics.radiusControl, style: .continuous
                            )
                            .fill(theme.palette.appBackground.opacity(0.6))
                        )
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(goal, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Copy goal")
                    .accessibilityLabel("Copy goal to paste into the coordinator's terminal")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Door 2: template

    private var templateDoor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ConductorBundledTemplateCatalog.templates) { template in
                    EnsembleTemplateRow(
                        template: template,
                        isSelected: selectedTemplateID == template.id,
                        select: { selectedTemplateID = template.id }
                    )
                }
            }
            if let message = templateLibraryModel.operationMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            if let error = templateLibraryModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.error)
            }
            Text("Copies real agent and workflow files into .rafu/ so you can read and edit them.")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pendingReplacementPresented: Binding<Bool> {
        Binding(
            get: { templateLibraryModel.pendingReplacement != nil },
            set: { presented in
                if !presented {
                    templateLibraryModel.clearPendingReplacement()
                }
            })
    }

    private func startTemplateDoor() {
        guard let templateID = selectedTemplateID, session.rootURL != nil else { return }
        Task {
            await templateLibraryModel.instantiate(templateID: templateID, scope: .repository)
            openInstantiatedWorkflowIfReady(templateID: templateID)
        }
    }

    /// Opens the template's workflow file as an editor tab ONLY when
    /// instantiation actually completed (no pending conflict confirmation,
    /// no error) — a conflict leaves the confirmation dialog in charge, and
    /// the destructive-confirm branch above calls this again once resolved.
    private func openInstantiatedWorkflowIfReady(templateID: String) {
        guard templateLibraryModel.pendingReplacement == nil,
            templateLibraryModel.errorMessage == nil,
            let root = session.rootURL,
            let template = ConductorBundledTemplateCatalog.templates.first(where: {
                $0.id == templateID
            }),
            let workflowFile = template.files.last(where: { $0.kind == .workflow })
        else { return }
        let url = RafuDotDirectory(workspaceRoot: root).directoryURL
            .appending(path: workflowFile.relativePath, directoryHint: .notDirectory)
        session.open(
            WorkspaceFileNode(
                url: url,
                relativePath: ".rafu/\(workflowFile.relativePath)",
                isDirectory: false))
        dismiss()
    }

    // MARK: - Door 3: expert

    private var expertDoor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if workflowLaunchModel.isLoading {
                ProgressView("Reading .rafu files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workflowLaunchModel.workflows.isEmpty,
                workflowLaunchModel.errorMessage == nil
            {
                ContentUnavailableView {
                    Label("No Workflow Files", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(
                        "Add a repository or user Ensemble workflow, or use the template door instead."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Picker("Workflow file", selection: selectedWorkflowBinding) {
                        ForEach(workflowLaunchModel.workflows) { workflow in
                            Text("\(workflow.displayName) — \(workflow.scope.displayName)")
                                .tag(Optional(workflow.id))
                        }
                    }
                    TextField("Task prompt", text: $expertTaskPrompt, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Base reference", text: $expertBaseReference)
                        .help("Branch, tag, or commit. Defaults to the current HEAD.")
                    if let workflow = workflowLaunchModel.selectedWorkflow, !workflow.issues.isEmpty
                    {
                        Section("Fix Before Running") {
                            ForEach(workflow.issues) { issue in
                                Label(
                                    issue.line.map { "Line \($0): \(issue.message)" }
                                        ?? issue.message,
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(theme.palette.error)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            if !session.canStartConductorWorkflowRun {
                Label(capReasonText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.warning)
            }
            if let error = expertWorkflowStartError ?? workflowLaunchModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.error)
            }
        }
    }

    private var selectedWorkflowBinding: Binding<String?> {
        Binding(
            get: { workflowLaunchModel.selectedWorkflowID },
            set: { newValue in
                guard let newValue else { return }
                workflowLaunchModel.selectWorkflow(id: newValue)
            })
    }

    /// Mirrors `ConductorNewRunSheet`'s own `canStart` exactly: it checks the
    /// LOCAL `expertTaskPrompt` binding rather than
    /// `workflowLaunchModel.canStart`, because that model's own `taskPrompt`
    /// is only synced into it right before `makeRequest()` — reading it here
    /// would disable the button on a stale empty string.
    private var expertCanStart: Bool {
        guard !expertTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard
            !workflowLaunchModel.isLoading,
            !isStartingExpertWorkflow,
            workflowLaunchModel.selectedWorkflow?.isLaunchable == true,
            let stepCount = workflowLaunchModel.selectedWorkflow?.definition?.steps.count
        else { return false }
        return workflowLaunchModel.resolvedRoles.count == stepCount
    }

    /// Reuses `ConductorConcurrentRunError`'s own wording instead of writing
    /// a second copy of the cap message.
    private var capReasonText: String {
        ConductorConcurrentRunError.activeLimitReached(limit: windowCap).errorDescription
            ?? "This window is at its Ensemble run limit."
    }

    private func startExpertWorkflow() {
        guard !isStartingExpertWorkflow else { return }
        isStartingExpertWorkflow = true
        expertWorkflowStartError = nil
        workflowLaunchModel.taskPrompt = expertTaskPrompt
        workflowLaunchModel.baseReference = expertBaseReference
        Task {
            defer { isStartingExpertWorkflow = false }
            do {
                let request = try workflowLaunchModel.makeRequest()
                // Free slots held by runs that already finished, so the cap
                // counts only genuinely active pipelines (mirrors the panel's
                // own New Run sheet).
                session.conductorConcurrentRuns.removeFinishedRuns()
                let launcher = WorkspaceConductorRunLauncher(
                    workspaceSession: session, runID: request.runID)
                let controller = try await session.conductorConcurrentRuns.start(
                    request, launcher: launcher)
                if case .failed(_, let reason) = controller.state {
                    expertWorkflowStartError = reason
                    return
                }
                if controller.isInFlight {
                    session.navigatorMode = .runs
                    dismiss()
                }
            } catch {
                expertWorkflowStartError =
                    (error as? LocalizedError)?.errorDescription
                    ?? "Rafu could not start the Ensemble workflow."
            }
        }
    }
}

/// A single selectable CLI row: icon, name, and — when disabled — a stated
/// reason (glyph + text, never color alone). Visual structure mirrors
/// `AgentTerminalSheet`'s own picker row.
private struct EnsembleCLIPickerRow: View {
    let option: AgentTerminalOption
    let isSelected: Bool
    let reason: String?
    let select: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                FileIconView(icon: option.icon, size: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.palette.textPrimary)
                    if let reason {
                        Label(reason, systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(theme.palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.palette.accent)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(isSelected ? theme.palette.selection : theme.palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.palette.accent : theme.palette.borderSubtle)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!option.isReady)
        .help(reason ?? "Use \(option.displayName) as the coordinator")
        .accessibilityLabel(reason.map { "\(option.displayName), \($0)" } ?? option.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A single selectable bundled-template row: name, one-line summary, and a
/// checkmark when selected. Templates are never disabled.
private struct EnsembleTemplateRow: View {
    let template: ConductorBundledTemplate
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(template.summary)
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.palette.accent)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(isSelected ? theme.palette.selection : theme.palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.palette.accent : theme.palette.borderSubtle)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(template.displayName), \(template.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
