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
/// async entry point, called only from the canvas's `.task`.
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
            _ name: String,
            _ providerModelDefaults: [ConductorCLIID: String],
            _ session: WorkspaceSession
        ) async throws -> ConductorCoordinatorSession

    var door: EnsembleDoor = .guided

    private(set) var cliOptions: [AgentTerminalOption] = []
    var selectedProvider: ConductorCLIID?
    var model = ""
    var goal = ""

    /// The user-typed Ensemble name. Empty means "use the suggestion" — the
    /// field's placeholder shows exactly what will be used, so a blank field
    /// is never an unnamed run.
    var name = ""

    var maxConcurrent = 3
    var maxTotal = 12
    var allowedProviders: Set<ConductorCLIID> = []
    var deadlineChoice: EnsembleGrantDeadline = .none

    /// This Ensemble's model choice per allowed CLI, so one pipeline can run
    /// one model on one CLI and another elsewhere. `""`/absent means "no
    /// choice here" and falls through to the Settings default.
    ///
    /// Keyed by CLI rather than held in one field, which IS the per-CLI
    /// equivalent of the coordinator field's unconditional reset: a value
    /// stored under Codex can never be read for Claude Code, so the
    /// cross-vendor contamination the coordinator guard exists to prevent is
    /// unrepresentable here. Disallowing a CLI drops its entry, so
    /// re-allowing it re-seeds from that CLI's own Settings default rather
    /// than resurrecting a stale pick.
    private(set) var providerModels: [ConductorCLIID: String] = [:]

    private(set) var isStarting = false
    var errorMessage: String?

    /// Non-`nil` once the coordinator has actually launched — the signal the
    /// canvas uses to show the copyable-goal confirmation row. Every current
    /// CLI's launch shape has no initial-prompt argument
    /// (`AgentTerminalLaunchShape.arguments(model:)` only ever appends a
    /// model flag), so this row is unconditional for Door 1, never a
    /// per-CLI capability check.
    private(set) var postLaunchGoalToPaste: String?

    @ObservationIgnored
    private let adapters: [any ConductorCLIAdapter]
    /// Each adapter's shipped model list, read once at construction.
    /// `curatedModels()` is contractually pure — no process, no filesystem,
    /// no network — which is the same reason `ConductorSettingsModel` reads
    /// it in `init`. Discovery, which DOES run the user's CLI, is not done
    /// here: opening this canvas must never invoke a CLI behind their back.
    @ObservationIgnored
    private let curatedModelsByID: [ConductorCLIID: [ConductorModelChoice]]
    /// Results of discovery passes the user already ran elsewhere (today,
    /// Settings → Agents → "Refresh models"). Reading this spawns nothing —
    /// it is a plain in-memory/`UserDefaults` cache — which is what lets the
    /// canvas offer the SAME catalog Settings offers while keeping the rule
    /// above intact. Deliberately NOT `@ObservationIgnored`: the cache is
    /// itself `@Observable`, so an open canvas picks up a refresh live.
    private let discoveredModels: ConductorDiscoveredModelCache
    @ObservationIgnored
    private let defaultModelStore: ConductorDefaultModelStore
    @ObservationIgnored
    private let clock: Clock
    @ObservationIgnored
    private let launch: Launch
    /// The timestamp fallback name, formatted at most once per canvas.
    /// `suggestedName(for:)` runs from `body` while the user types the goal,
    /// and date formatting is the only non-trivial work in it.
    @ObservationIgnored
    private var cachedTimestampName: String?

    init(
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        defaultModelStore: ConductorDefaultModelStore = ConductorDefaultModelStore(),
        discoveredModels: ConductorDiscoveredModelCache = .shared,
        clock: @escaping Clock = Date.init,
        launch: @escaping Launch = {
            provider, model, goal, grant, name, providerModelDefaults, session in
            try await ConductorCoordinatorLauncher().start(
                provider: provider, model: model, goal: goal, grant: grant, label: name,
                providerModelDefaults: providerModelDefaults,
                in: session)
        }
    ) {
        self.adapters = adapters
        self.curatedModelsByID = Dictionary(
            adapters.map { ($0.id, $0.curatedModels()) },
            uniquingKeysWith: { first, _ in first })
        self.discoveredModels = discoveredModels
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
            for id in readyIDs { setAllowed(true, for: id) }
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
        model = settingsDefaultModel(for: id) ?? ""
    }

    // MARK: - Models

    /// The user's Settings → Agents default for this CLI, as probed. `nil`
    /// when nothing is set (`AgentTerminalLaunchService` already trims and
    /// empty-drops it).
    func settingsDefaultModel(for id: ConductorCLIID) -> String? {
        cliOptions.first { $0.id == id }?.defaultModel
    }

    /// What this CLI's pickers may list: its curated catalog, then anything a
    /// discovery pass already found, then the user's Settings default when
    /// that is a model neither list contains — otherwise a hand-typed
    /// Settings default would be missing from the very picker meant to show
    /// it.
    ///
    /// The curated+discovered merge goes through `ConductorModelCatalog`, the
    /// same call Settings → Agents makes, so the two surfaces cannot present
    /// different catalogs for one CLI. That divergence was the bug: Settings
    /// listed a refreshed 190-model Cursor catalog while this canvas listed
    /// three curated entries, for the same CLI on the same machine.
    func availableModels(for id: ConductorCLIID) -> [ConductorModelChoice] {
        let known = ConductorModelCatalog.merge(
            curated: curatedModelsByID[id] ?? [],
            discovered: discoveredModels.models(for: id))
        guard
            let settingsChoice = ConductorModelCatalog.choice(
                for: settingsDefaultModel(for: id), in: known),
            settingsChoice.source == .custom
        else { return known }
        return known + [settingsChoice]
    }

    /// This Ensemble's per-CLI choice, or `nil` when the user has not made
    /// one and the Settings default should apply.
    func ensembleModel(for id: ConductorCLIID) -> String? {
        ConductorModelResolution.normalized(providerModels[id])
    }

    func setEnsembleModel(_ value: String, for id: ConductorCLIID) {
        providerModels[id] = value
    }

    /// Which model an allowed CLI will actually run, through the ONE shared
    /// resolver. There is no per-role explicit value at creation time — a
    /// role's own `model:` is read from its agent file when a child run
    /// starts — so this ensemble-level pick IS the top of the chain here.
    func modelResolution(for id: ConductorCLIID) -> ConductorModelResolution {
        ConductorModelResolution.resolve(
            explicit: nil,
            ensembleDefault: ensembleModel(for: id),
            settingsDefault: settingsDefaultModel(for: id),
            catalog: availableModels(for: id))
    }

    /// Which model the coordinator itself will run.
    ///
    /// The Settings default is PREFILLED into `model` by `selectProvider`
    /// (the cross-vendor reset guard), so a field value equal to that default
    /// is not a choice the user made — reporting it as `.explicit` would
    /// claim one they never made. It is handed to the resolver as what it
    /// actually is, which is why the card can honestly say "your default for
    /// this CLI" instead of implying a pick.
    var coordinatorModelResolution: ConductorModelResolution? {
        guard let selectedProvider else { return nil }
        let settingsDefault = settingsDefaultModel(for: selectedProvider)
        let typed = ConductorModelResolution.normalized(model)
        let explicit = typed == ConductorModelResolution.normalized(settingsDefault) ? nil : typed
        return ConductorModelResolution.resolve(
            explicit: explicit,
            ensembleDefault: nil,
            settingsDefault: settingsDefault,
            catalog: availableModels(for: selectedProvider))
    }

    /// The per-provider defaults carried alongside — never inside — the
    /// grant, for the CLIs the coordinator is actually allowed to reach.
    /// A CLI with no choice contributes nothing, so the child-run path falls
    /// through to Settings exactly as it would have before.
    func providerModelDefaults() -> [ConductorCLIID: String] {
        var result: [ConductorCLIID: String] = [:]
        for id in allowedProviders {
            guard let model = ensembleModel(for: id) else { continue }
            result[id] = model
        }
        return result
    }

    // MARK: - Allowed CLIs

    func isAllowed(_ id: ConductorCLIID) -> Bool {
        allowedProviders.contains(id)
    }

    /// The one seam for the allowed-CLI grid, so clearing a CLI's model entry
    /// can never be forgotten at a call site.
    ///
    /// Allowing a CLI deliberately seeds NO model. The picker then reads "CLI
    /// default" and the caption names whatever Settings contributes, which is
    /// the truth; pre-filling the Settings value as an Ensemble-level choice
    /// would turn an inherited default into a claimed pick and make the
    /// resolver report `.ensembleDefault` for a decision the user never made.
    func setAllowed(_ allowed: Bool, for id: ConductorCLIID) {
        if allowed {
            allowedProviders.insert(id)
        } else {
            allowedProviders.remove(id)
            providerModels.removeValue(forKey: id)
        }
    }

    func toggleAllowed(_ id: ConductorCLIID) {
        setAllowed(!isAllowed(id), for: id)
    }

    /// The allowed CLIs in the probed registry's own order, so the per-CLI
    /// model rows never reshuffle as the set changes (a `Set` has no order).
    var allowedOptionsInRegistryOrder: [AgentTerminalOption] {
        cliOptions.filter { allowedProviders.contains($0.id) }
    }

    /// `nil` only for a ready CLI. The not-authenticated case reproduces the
    /// adapter's own hint text verbatim (never rewritten); the not-installed
    /// case is reworded for THIS canvas's action rather than reusing the
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

    // MARK: - Naming

    /// The name Rafu uses when the name field is left blank: the first
    /// meaningful line of `source` (the goal for Door 1, the task prompt for
    /// Door 3) with Markdown list/heading/quote markers stripped, or a
    /// timestamped fallback when there is no such line yet.
    ///
    /// Pure apart from memoizing the timestamp string, so it is safe to call
    /// from `body` on every keystroke and testable without a view.
    func suggestedName(for source: String) -> String {
        if let derived = Self.deriveName(from: source) { return derived }
        if let cachedTimestampName { return cachedTimestampName }
        let formatted = clock().formatted(date: .abbreviated, time: .shortened)
        let fallback = "Ensemble \(formatted)"
        cachedTimestampName = fallback
        return fallback
    }

    /// What actually reaches the coordinator session / run manifest: the
    /// user's typed name when they gave one, otherwise the suggestion the
    /// placeholder already showed them.
    func effectiveName(for source: String) -> String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? suggestedName(for: source) : typed
    }

    /// The first line of `source` that carries words, with leading Markdown
    /// structure (`#`, `-`, `*`, `>`, `1.`) and inline emphasis characters
    /// removed, bounded to 60 characters on a word boundary. `nil` when the
    /// text has no such line.
    nonisolated static func deriveName(from source: String) -> String? {
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#>-*+".contains(first) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let dot = line.firstIndex(of: "."),
                line[line.startIndex..<dot].allSatisfy(\.isNumber),
                line.startIndex != dot
            {
                line = String(line[line.index(after: dot)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return bounded(line, limit: 60)
        }
        return nil
    }

    private nonisolated static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = text.prefix(limit)
        if let lastSpace = clipped.lastIndex(of: " "),
            clipped.distance(
                from: clipped.startIndex, to: lastSpace) > limit / 2
        {
            return String(clipped[clipped.startIndex..<lastSpace]) + "…"
        }
        return String(clipped) + "…"
    }

    // MARK: - Grant and launch

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
    /// `ConductorCoordinatorLauncher.start` by default). On success the canvas
    /// STAYS open showing `postLaunchGoalToPaste` — `finishAndShowGraph(in:)`
    /// is the explicit "Done" verb that actually lands the user on the graph
    /// canvas, so the copyable goal is never a toast the user might miss. On
    /// failure nothing is registered and `errorMessage` is set; the canvas
    /// stays open with the form untouched.
    ///
    /// The goal handed over is the user's text with only outer whitespace
    /// trimmed: the live-Markdown pane renders `goal`, it never rewrites it,
    /// because this string is pasted verbatim into a CLI prompt.
    @discardableResult
    func start(in session: WorkspaceSession) async -> Bool {
        guard let selectedProvider, isEnabled(selectedProvider) else { return false }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return false }

        isStarting = true
        errorMessage = nil
        defer { isStarting = false }

        let grant = makeGrant(windowCap: session.conductorConcurrentRuns.activeLimit)
        // The same resolver the coordinator card displays, so what launches
        // is what the user read — never a second precedence rule.
        let coordinatorModel = coordinatorModelResolution?.modelID
        let ensembleName = effectiveName(for: goal)
        session.beginEnsembleStartLaunch()
        defer { session.endEnsembleStartLaunch() }
        do {
            _ = try await launch(
                selectedProvider,
                coordinatorModel,
                trimmedGoal,
                grant,
                ensembleName,
                providerModelDefaults(),
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
        postLaunchGoalToPaste = nil
    }
}

/// "New Ensemble…" (⌘⇧E / Rafu menu / palette / Runs-panel button): the one
/// cold-start canvas a user needs, ever. UX-01 re-hosts C8-07's unchanged
/// three-door workflow as an editor tab with close/Esc semantics; UX2-02
/// re-lays it out at full editor width as a two-column workbench — controls
/// left, a live-Markdown goal surface right — instead of one narrow centered
/// column of stacked form sections.
struct EnsembleStartCanvas: View {
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

    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(theme.palette.borderSubtle)
            header
            Divider().overlay(theme.palette.borderSubtle)
            doorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().overlay(theme.palette.borderSubtle)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.editorBackground)
        .onExitCommand(perform: session.closeEnsembleStart)
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

    private var tabStrip: some View {
        HStack(spacing: 0) {
            AttachedWorkbenchTab(isSelected: true) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.hexagongrid")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.info)
                        .accessibilityHidden(true)
                    Text("New Ensemble")
                        .lineLimit(1)
                    AttachedWorkbenchTabCloseButton(
                        accessibilityLabel: "Close New Ensemble",
                        help: "Close New Ensemble",
                        action: session.closeEnsembleStart
                    )
                }
                .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: RafuMetrics.tabBarHeight)
        .background(theme.palette.tabBarBackground)
    }

    // MARK: - Header (title, name, doors)

    private var header: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            HStack(spacing: RafuMetrics.space3) {
                Label("New Ensemble", systemImage: "circle.hexagongrid")
                    .font(.headline)
                    .foregroundStyle(theme.palette.textPrimary)
                Divider()
                    .frame(height: 18)
                nameField
                Spacer(minLength: RafuMetrics.space2)
            }
            RafuSegmentedPicker(items: EnsembleDoor.allCases, selection: $model.door) {
                $0.title
            }
        }
        .padding(.horizontal, RafuMetrics.sheetPadding)
        .padding(.vertical, RafuMetrics.space2)
        .frame(minHeight: Self.headerTargetHeight, alignment: .top)
    }

    /// The name that flows into `ConductorCoordinatorSession.label` (Door 1)
    /// and `ConductorWorkflowRunRequest.label` (Door 3). Left blank, the
    /// placeholder's suggestion is what actually gets used — so the user can
    /// always read the name they are about to create.
    private var nameField: some View {
        HStack(spacing: RafuMetrics.space1) {
            Text("Name")
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
            TextField(model.suggestedName(for: nameSourceText), text: $model.name)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(theme.palette.textPrimary)
                .focused($isNameFieldFocused)
                .rafuField(isFocused: isNameFieldFocused)
                .frame(width: 260)
                .accessibilityLabel("Ensemble name")
                .help(
                    "Names this Ensemble in the graph and the Runs panel. Blank uses \(model.suggestedName(for: nameSourceText))."
                )
        }
    }

    /// Door 1 names itself after the goal; Door 3 after its task prompt.
    /// Door 2 writes files rather than starting a run, so it has no source —
    /// the timestamp fallback applies.
    private var nameSourceText: String {
        switch model.door {
        case .guided: model.goal
        case .template: ""
        case .expert: expertTaskPrompt
        }
    }

    // MARK: - Door content

    @ViewBuilder
    private var doorContent: some View {
        if isShowingLaunchConfirmation {
            launchConfirmation
                .padding(RafuMetrics.sheetPadding)
        } else {
            switch model.door {
            case .guided:
                guidedDoor
            case .template:
                templateDoor
                    .padding(RafuMetrics.sheetPadding)
            case .expert:
                expertDoor
                    .padding(RafuMetrics.sheetPadding)
            }
        }
    }

    // MARK: - Door 1: guided (two columns)

    private var windowCap: Int {
        session.conductorConcurrentRuns.activeLimit
    }

    /// Full editor width, in goal-first source order. The common task starts
    /// in a 420 pt writing pane; a 4 pt app-background gutter separates it
    /// from the fixed 300 pt configuration rail without using a divider.
    private var guidedDoor: some View {
        HStack(alignment: .top, spacing: 0) {
            EnsembleGoalPane(text: $model.goal)
                .frame(
                    minWidth: Self.goalPaneMinimumWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .background(ensembleSurface)

            Rectangle()
                .fill(theme.palette.appBackground)
                .frame(width: RafuMetrics.workbenchInset)
                .accessibilityHidden(true)

            guidedControlsColumn
                .frame(width: Self.configurationRailWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(ensembleSurface)
        }
    }

    nonisolated static let goalPaneMinimumWidth: CGFloat = 420
    nonisolated static let configurationRailWidth: CGFloat = 300
    nonisolated static let headerTargetHeight: CGFloat = 88
    nonisolated static let footerMinimumHeight: CGFloat = 52

    private var ensembleSurface: some View {
        RoundedRectangle(cornerRadius: RafuMetrics.radiusEditorGroup, style: .continuous)
            .fill(theme.palette.editorBackground)
            .overlay(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusEditorGroup, style: .continuous)
                    .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var guidedControlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RafuMetrics.space5) {
                coordinatorSection
                budgetSection
                allowedCLISection
            }
            .padding(RafuMetrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var coordinatorSection: some View {
        EnsembleControlSection(
            title: "Lead coordinator", systemImage: "person.badge.shield.checkmark"
        ) {
            if model.cliOptions.isEmpty {
                HStack(spacing: RafuMetrics.space2) {
                    ProgressView().controlSize(.small)
                    Text("Checking installed CLIs…")
                        .font(.callout)
                        .foregroundStyle(theme.palette.textSecondary)
                }
            } else {
                EnsembleCLISelectionList(options: model.cliOptions) { option in
                    let isSelected = model.selectedProvider == option.id
                    let resolution = model.modelResolution(for: option.id)
                    EnsembleCLISelectionRow(
                        option: option,
                        selection: .lead(isSelected: isSelected),
                        unavailableReason: model.disableReason(option.id),
                        activate: { selectProvider(option) }
                    ) {
                        if isSelected, let coordinatorResolution = model.coordinatorModelResolution
                        {
                            EnsembleModelField(
                                label: "Lead coordinator model",
                                available: model.availableModels(for: option.id),
                                resolution: coordinatorResolution,
                                value: $model.model
                            )
                        } else {
                            Text(resolution.detailedLabel)
                                .font(.caption)
                                .foregroundStyle(theme.palette.textMuted)
                                .accessibilityLabel("Resolved model: \(resolution.detailedLabel)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Lead coordinator, single selection")
                }
            }
        }
    }

    private var budgetSection: some View {
        // The consent model (C8-coordinator-ux.md): the grant is always
        // visible here, never buried in Settings. Usage ceiling is
        // deliberately absent from v1 UI — the grant type supports it, but no
        // per-provider usage editor exists yet.
        EnsembleControlSection(
            title: "Budget grant", systemImage: "gauge.with.dots.needle.33percent"
        ) {
            Stepper(
                "Max concurrent child runs: \(model.maxConcurrent)",
                value: $model.maxConcurrent,
                in: 1...max(1, min(3, windowCap))
            )
            .font(.callout)
            Text("Capped at \(windowCap) per window.")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
            Stepper(
                "Max total child runs: \(model.maxTotal)",
                value: $model.maxTotal,
                in: 1...50
            )
            .font(.callout)
            Picker("Deadline", selection: $model.deadlineChoice) {
                ForEach(EnsembleGrantDeadline.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .font(.callout)
            Text(
                "The coordinator can start at most this many child runs and reach only the CLIs you allow."
            )
            .font(.caption)
            .foregroundStyle(theme.palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allowedCLISection: some View {
        EnsembleControlSection(title: "Allowed CLIs", systemImage: "checklist") {
            if model.cliOptions.isEmpty {
                Text("No CLIs probed yet.")
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
            } else {
                EnsembleCLISelectionList(options: model.cliOptions) { option in
                    let isAllowed = model.isAllowed(option.id)
                    let resolution = model.modelResolution(for: option.id)
                    EnsembleCLISelectionRow(
                        option: option,
                        selection: .allowed(isSelected: isAllowed),
                        unavailableReason: model.disableReason(option.id),
                        activate: { toggleAllowed(option) }
                    ) {
                        if isAllowed {
                            EnsembleModelField(
                                label: "\(option.displayName) allowed model",
                                available: model.availableModels(for: option.id),
                                resolution: resolution,
                                value: allowedModelBinding(option.id)
                            )
                        } else {
                            Text(resolution.detailedLabel)
                                .font(.caption)
                                .foregroundStyle(theme.palette.textMuted)
                                .accessibilityLabel("Resolved model: \(resolution.detailedLabel)")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Allowed CLIs, multiple selection")
                // Names where the longer lists come from. Opening this canvas
                // deliberately runs no CLI, so a CLI that can list its own
                // models shows that list only after the user asks for it in
                // Settings — this says so rather than leaving the shorter
                // list looking like the whole truth.
                Text(
                    "Each allowed CLI runs the model chosen here unless a role names its own. For CLIs that can list their own models, use Settings → Agents → Refresh models to show the full catalog here too."
                )
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer and primary action

    private var footer: some View {
        HStack(spacing: RafuMetrics.space3) {
            if let doorErrorMessage {
                Label(doorErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(theme.palette.error)
                    .lineLimit(2)
                    .accessibilityLabel("Cannot start: \(doorErrorMessage)")
            }
            Spacer(minLength: RafuMetrics.space3)
            if isBusy {
                ProgressView().controlSize(.small)
            }
            if !isShowingLaunchConfirmation {
                Button("Close", action: session.closeEnsembleStart)
                    .buttonStyle(RafuSecondaryButtonStyle())
            }
            Button(primaryTitle) { primaryAction() }
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canStartPrimary)
        }
        .padding(.horizontal, RafuMetrics.sheetPadding)
        .padding(.vertical, RafuMetrics.space2)
        .frame(minHeight: Self.footerMinimumHeight)
        .background(theme.palette.tabBarBackground)
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

    /// Per-CLI, so a value stored for one vendor can never be read for
    /// another — the structural equivalent of the coordinator field's reset
    /// on provider switch.
    private func allowedModelBinding(_ id: ConductorCLIID) -> Binding<String> {
        Binding(
            get: { model.ensembleModel(for: id) ?? "" },
            set: { model.setEnsembleModel($0, for: id) })
    }

    private func selectProvider(_ option: AgentTerminalOption) {
        guard option.isReady else { return }
        model.selectProvider(option.id)
    }

    private func toggleAllowed(_ option: AgentTerminalOption) {
        guard option.isReady else { return }
        model.toggleAllowed(option.id)
    }

    private var launchConfirmation: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            Label("Coordinator Launched", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(theme.palette.textPrimary)
            Text(
                "This CLI has no way to accept an initial prompt automatically. Paste your goal into its terminal tab."
            )
            .font(.callout)
            .foregroundStyle(theme.palette.textSecondary)
            if let goal = model.postLaunchGoalToPaste {
                HStack(alignment: .top, spacing: RafuMetrics.space2) {
                    ScrollView {
                        Text(goal)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
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
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Door 2: template

    private var templateDoor: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 260, maximum: 420), spacing: RafuMetrics.space2)
                ],
                alignment: .leading,
                spacing: RafuMetrics.space2
            ) {
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
        session.closeEnsembleStart()
    }

    // MARK: - Door 3: expert

    private var expertDoor: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
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
                .frame(maxWidth: 720)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedWorkflowBinding: Binding<String?> {
        Binding(
            get: { workflowLaunchModel.selectedWorkflowID },
            set: { newValue in
                guard let newValue else { return }
                workflowLaunchModel.selectWorkflow(id: newValue)
            })
    }

    /// Mirrors `ConductorNewRunCanvas`'s own `canStart` exactly: it checks the
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
        let ensembleName = model.effectiveName(for: expertTaskPrompt)
        Task {
            defer { isStartingExpertWorkflow = false }
            do {
                // `label` is the existing manifest-level name seam
                // (`ConductorRunManifest.label`), already rendered by the
                // graph and the Runs panel — not a parallel field.
                var request = try workflowLaunchModel.makeRequest()
                request.label = ensembleName
                // Free slots held by runs that already finished, so the cap
                // counts only genuinely active pipelines (mirrors the panel's
                // own New Run canvas).
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
                    session.closeEnsembleStart()
                }
            } catch {
                expertWorkflowStartError =
                    (error as? LocalizedError)?.errorDescription
                    ?? "Rafu could not start the Ensemble workflow."
            }
        }
    }
}

/// A titled block in the guided door's left rail: glyph + title + hairline,
/// then a leading-aligned content stack. Keeps the rail's three sections
/// reading as one rhythm without a `Form`, whose grouped style forces the
/// inset-list look this layout deliberately drops.
private struct EnsembleControlSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.palette.accent)
                        .accessibilityLabel("Selected")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
