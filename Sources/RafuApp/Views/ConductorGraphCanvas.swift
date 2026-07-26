import SwiftUI

/// Editor-hosted, workspace-wide Ensemble graph route. The graph is a
/// read-only projection: workflow authoring stays in the Markdown definition
/// files, while every action here delegates to the same controller verbs as
/// run detail.
struct ConductorGraphCanvas: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme
    @State private var graph = ConductorGraph.empty
    @State private var selectedNodeID: String?
    @State private var pendingDiscardRunID: String?
    @State private var dirtyDiscardRunID: String?

    var body: some View {
        let refreshInput = graphRefreshInput

        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(theme.palette.borderSubtle)
            if graph.nodes.isEmpty {
                ContentUnavailableView(
                    "No Ensemble Runs",
                    systemImage: WorkspaceNavigatorMode.runs.symbolName,
                    description: Text(
                        "Runs appear here as a read-only graph once they are started.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                graphContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.editorBackground)
        .task(id: refreshInput) {
            let projected = await ConductorGraphModel.project(
                manifests: refreshInput.manifests,
                liveStates: Dictionary(
                    uniqueKeysWithValues: refreshInput.liveStates.map { ($0.runID, $0.state) }),
                coordinators: refreshInput.coordinators)
            guard !Task.isCancelled else { return }
            graph = projected
            if let selectedNodeID, !graph.nodes.contains(where: { $0.id == selectedNodeID }) {
                self.selectedNodeID = nil
            }
        }
        .alert(
            "Discard the Run Worktree?",
            isPresented: Binding(
                get: { pendingDiscardRunID != nil },
                set: { if !$0 { pendingDiscardRunID = nil } })
        ) {
            Button("Discard", role: .destructive) {
                guard let runID = pendingDiscardRunID else { return }
                pendingDiscardRunID = nil
                Task { await requestDiscard(runID: runID) }
            }
            Button("Cancel", role: .cancel) {
                pendingDiscardRunID = nil
            }
        } message: {
            Text("This removes the run worktree after Git confirms it has no uncommitted changes.")
        }
        .alert(
            "Discard Changes Anyway?",
            isPresented: Binding(
                get: { dirtyDiscardRunID != nil },
                set: { if !$0 { dirtyDiscardRunID = nil } })
        ) {
            Button("Discard Anyway", role: .destructive) {
                guard let runID = dirtyDiscardRunID else { return }
                dirtyDiscardRunID = nil
                Task {
                    _ = await session.workflowController(forRunID: runID)?
                        .discardWorktree(confirmedDirty: true)
                }
            }
            Button("Cancel", role: .cancel) {
                dirtyDiscardRunID = nil
            }
        } message: {
            Text("Discarding now permanently removes changes in the run worktree.")
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 7) {
            Image(systemName: WorkspaceNavigatorMode.runs.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.info)
                .accessibilityHidden(true)
            Text("Ensemble Graph")
                .lineLimit(1)
                .foregroundStyle(theme.palette.textPrimary)
            Button("Close Graph", systemImage: "xmark", action: session.closeConductorGraph)
                .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                .accessibilityHint("Closes the Ensemble graph")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: RafuMetrics.tabBarHeight)
        .background(theme.palette.tabBarBackground)
    }

    private var graphContent: some View {
        let layout = ConductorGraphLayout(graph: graph)

        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard
                            let start = layout.trailingEdge(of: edge.from),
                            let end = layout.leadingEdge(of: edge.to)
                        else { continue }
                        let bend = max(24, (end.x - start.x) / 2)
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(
                            to: end,
                            control1: CGPoint(x: start.x + bend, y: start.y),
                            control2: CGPoint(x: end.x - bend, y: end.y))
                        context.stroke(
                            path,
                            with: .color(theme.palette.borderStrong),
                            style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                    }
                }
                .accessibilityHidden(true)

                ForEach(graph.nodes) { node in
                    if let center = layout.center(of: node.id) {
                        ConductorGraphNodeCard(
                            node: node,
                            isSelected: selectedNodeID == node.id,
                            session: session,
                            select: { selectedNodeID = node.id },
                            showRunDetail: { showRunDetail(for: node) },
                            revealCoordinator: { revealCoordinator(for: node) },
                            revealTerminal: { revealTerminal(for: node) },
                            openArtifact: { openArtifact(for: node) },
                            openEvidence: { openEvidence(for: node) },
                            approveGate: { approveGate(for: node) },
                            reviseGate: { reviseGate(for: node) },
                            abortGate: { abortGate(for: node) },
                            retryFailedStep: { retryFailedStep(for: node) },
                            retryInterruptedStep: { retryInterruptedStep(for: node) },
                            abortInterruptedRun: { abortInterruptedRun(for: node) },
                            keepInterruptedWorktree: { keepInterruptedWorktree(for: node) },
                            openMergeDiff: { openMergeDiff(for: node) },
                            applyMerge: { applyMerge(for: node) },
                            discardMerge: { discardMerge(for: node) }
                        )
                        .position(center)
                    }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .padding(RafuMetrics.space4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Ensemble run graph")
    }

    private var graphRefreshInput: ConductorGraphRefreshInput {
        let manifests = session.conductorRuns
        let liveStates = manifests.compactMap { manifest -> ConductorGraphLiveStateInput? in
            guard let controller = session.workflowController(forRunID: manifest.id),
                controller.manifest?.id == manifest.id
            else { return nil }
            return ConductorGraphLiveStateInput(runID: manifest.id, state: controller.state)
        }
        let coordinators = session.conductorCoordinatorSessions.map {
            CoordinatorNodeInput(
                id: $0.id,
                title: $0.displayTitle,
                provider: $0.provider,
                terminalSessionID: $0.terminalSessionID,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt)
        }
        return ConductorGraphRefreshInput(
            manifests: manifests,
            liveStates: liveStates.sorted { $0.runID < $1.runID },
            coordinators: coordinators)
    }

    private func manifest(for node: ConductorGraphNode) -> ConductorRunManifest? {
        guard let runID = node.runID else { return nil }
        if let live = session.workflowController(forRunID: runID)?.manifest, live.id == runID {
            return live
        }
        return session.conductorRuns.first { $0.id == runID }
    }

    private func workflow(for node: ConductorGraphNode) -> ConductorWorkflowController? {
        guard let runID = node.runID else { return nil }
        return session.workflowController(forRunID: runID)
    }

    private func showRunDetail(for node: ConductorGraphNode) {
        guard let runID = node.runID else { return }
        selectedNodeID = node.id
        session.showConductorRunDetail(runID)
    }

    private func revealCoordinator(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        guard
            let terminalID = session.conductorCoordinatorSessions.first(where: {
                $0.id == node.id && $0.endedAt == nil
            })?.terminalSessionID
        else { return }
        session.revealTerminalSession(terminalID)
    }

    private func revealTerminal(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        guard let runID = node.runID, let stepIndex = node.stepIndex else { return }
        if let workflow = workflow(for: node) {
            workflow.revealLiveTerminal(stepIndex: stepIndex, in: session)
        } else {
            session.conductorRunController.revealLiveTerminal(for: runID, in: session)
        }
    }

    private func openArtifact(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        guard let manifest = manifest(for: node), let stepIndex = node.stepIndex else { return }
        let rows = ConductorRunPresentation.stepRows(for: manifest)
        guard let row = rows.first(where: { $0.index == stepIndex }), row.canOpenArtifact else {
            return
        }
        session.openFile(atRelativePath: row.artifactRelativePath)
    }

    private func openEvidence(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        guard let manifest = manifest(for: node), let stepIndex = node.stepIndex,
            manifest.steps.indices.contains(stepIndex),
            let evidencePath = manifest.steps[stepIndex].evidencePath
        else {
            showRunDetail(for: node)
            return
        }
        session.openFile(
            atRelativePath: ".rafu/runs/\(manifest.id)/\(evidencePath)/logs/output.log")
    }

    private func approveGate(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        Task { await workflow(for: node)?.approveGate() }
    }

    private func reviseGate(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        workflow(for: node)?.reviseArtifact(in: session)
    }

    private func abortGate(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        workflow(for: node)?.abortGate()
    }

    private func retryFailedStep(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        Task { await workflow(for: node)?.retryFailedStep() }
    }

    private func retryInterruptedStep(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        guard let runID = node.runID, let stepIndex = node.stepIndex,
            let workflow = session.adoptInterruptedRun(runID)
        else { return }
        Task { await workflow.retryInterruptedStep(stepIndex) }
    }

    private func abortInterruptedRun(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        guard let runID = node.runID else { return }
        session.adoptInterruptedRun(runID)?.abortInterruptedRun()
    }

    private func keepInterruptedWorktree(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        guard let runID = node.runID else { return }
        session.adoptInterruptedRun(runID)?.keepInterruptedWorktree()
    }

    private func openMergeDiff(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        guard let workflow = workflow(for: node), let file = workflow.mergeGateFiles.first else {
            return
        }
        Task { await workflow.presentMergeGateDiff(file, in: session) }
    }

    private func applyMerge(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        Task { await workflow(for: node)?.applyToWorkspace() }
    }

    private func discardMerge(for node: ConductorGraphNode) {
        selectedNodeID = node.id
        pendingDiscardRunID = node.runID
    }

    private func requestDiscard(runID: String) async {
        let result = await session.workflowController(forRunID: runID)?
            .discardWorktree(confirmedDirty: false)
        if result == .confirmationRequired {
            dirtyDiscardRunID = runID
        }
    }
}

private struct ConductorGraphNodeCard: View {
    let node: ConductorGraphNode
    let isSelected: Bool
    @Bindable var session: WorkspaceSession
    let select: () -> Void
    let showRunDetail: () -> Void
    let revealCoordinator: () -> Void
    let revealTerminal: () -> Void
    let openArtifact: () -> Void
    let openEvidence: () -> Void
    let approveGate: () -> Void
    let reviseGate: () -> Void
    let abortGate: () -> Void
    let retryFailedStep: () -> Void
    let retryInterruptedStep: () -> Void
    let abortInterruptedRun: () -> Void
    let keepInterruptedWorktree: () -> Void
    let openMergeDiff: () -> Void
    let applyMerge: () -> Void
    let discardMerge: () -> Void

    @Environment(\.rafuTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: primaryAction) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        ProviderBadge(provider: node.provider)
                        Text(kindLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.palette.textSecondary)
                        Spacer(minLength: 4)
                        statusLabel
                    }
                    Text(node.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(node.detail)
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(primaryHint)

            Spacer(minLength: 0)
            actionButtons
        }
        .padding(RafuMetrics.space3)
        .frame(
            width: ConductorGraphLayout.nodeSize.width,
            height: ConductorGraphLayout.nodeSize.height,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .fill(isSelected ? theme.palette.selection : theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? theme.palette.focusRing
                        : isSelected
                            ? theme.palette.borderStrong : theme.palette.borderSubtle,
                    style: StrokeStyle(
                        lineWidth: isFocused ? 2 : 1,
                        // A proposed ghost node (C8-04) is advisory, not an
                        // admitted run — a dashed border distinguishes it
                        // from every solid-bordered kind without adding a
                        // color-only signal (AGENTS: never color alone).
                        dash: node.kind == .proposedGhost ? [5, 4] : [])
                )
        )
        .contextMenu {
            contextMenuItems
        }
    }

    private var presentation: ConductorGraphNodePresentation {
        ConductorRunPresentation.graphNode(for: node.runState)
    }

    private var statusLabel: some View {
        Label(presentation.label, systemImage: presentation.symbol)
            .font(.caption)
            .foregroundStyle(statusColor)
            .labelStyle(.titleAndIcon)
    }

    private var statusColor: Color {
        switch node.runState {
        case .failed:
            theme.palette.error
        case .awaitingGate, .mergeGate, .interrupted:
            theme.palette.warning
        case .completed:
            theme.palette.success
        case .running:
            theme.palette.info
        case .pending, .blocked, .aborted, .ended:
            theme.palette.textSecondary
        }
    }

    /// The default route deliberately includes step nodes and any later
    /// graph kind that does not yet have bespoke chrome.
    private var kindLabel: String {
        switch node.kind {
        case .coordinator: "Coordinator"
        case .run: "Run"
        case .gate: "Gate"
        case .proposedGhost: "Proposed"
        default: "Step"
        }
    }

    private var accessibilityLabel: String {
        let provider = node.provider?.displayName ?? "Unknown provider"
        return
            "\(kindLabel), \(node.title), \(presentation.label), \(provider), \(node.detail)"
    }

    private var primaryHint: String {
        switch node.kind {
        case .coordinator:
            node.runState == .ended ? "Selects the ended coordinator" : "Reveals its terminal"
        case .run, .gate:
            "Shows this run's detail"
        default:
            switch node.runState {
            case .running:
                "Reveals the live terminal"
            case .completed:
                "Opens the handoff artifact"
            case .failed:
                "Opens the failure log"
            case .pending, .blocked, .awaitingGate, .interrupted, .aborted, .mergeGate, .ended:
                "Shows this run's detail"
            }
        }
    }

    private func primaryAction() {
        select()
        switch node.kind {
        case .coordinator:
            revealCoordinator()
        case .run, .gate:
            showRunDetail()
        default:
            switch node.runState {
            case .running:
                revealTerminal()
            case .completed:
                openArtifact()
            case .failed:
                openEvidence()
            case .pending, .blocked, .awaitingGate, .interrupted, .aborted, .mergeGate, .ended:
                showRunDetail()
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if node.kind != .coordinator {
            VStack(alignment: .leading, spacing: 5) {
                statusActions
                Button("Show Run Detail", action: selected(showRunDetail))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
    }

    @ViewBuilder
    private var statusActions: some View {
        switch node.runState {
        case .running where node.kind == .step:
            Button("Reveal Terminal", action: selected(revealTerminal))
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        case .completed where node.kind == .step:
            Button("Open Artifact", action: selected(openArtifact))
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        case .failed where node.kind == .step:
            HStack(spacing: 5) {
                Button("Open Evidence", action: selected(openEvidence))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Button("Retry", action: selected(retryFailedStep))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        case .interrupted where node.kind == .step:
            HStack(spacing: 5) {
                Button("Retry", action: selected(retryInterruptedStep))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Button("Abort", role: .destructive, action: selected(abortInterruptedRun))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                if hasWorktree {
                    Button("Keep", action: selected(keepInterruptedWorktree))
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                }
            }
        case .awaitingGate where node.kind == .gate:
            HStack(spacing: 5) {
                Button("Approve", action: selected(approveGate))
                    .buttonStyle(RafuProminentButtonStyle())
                Button("Revise", action: selected(reviseGate))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Button("Abort", role: .destructive, action: selected(abortGate))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        case .mergeGate where node.kind == .gate:
            HStack(spacing: 5) {
                Button("Open Diff", action: selected(openMergeDiff))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .disabled(!hasMergeDiff)
                Button("Apply", action: selected(applyMerge))
                    .buttonStyle(RafuProminentButtonStyle())
                Button("Discard", role: .destructive, action: selected(discardMerge))
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if node.kind == .coordinator {
            Button(
                node.runState == .ended ? "Select Coordinator" : "Reveal Coordinator Terminal",
                action: selected(revealCoordinator))
        } else {
            Button("Show Run Detail", action: selected(showRunDetail))
            switch node.runState {
            case .running where node.kind == .step:
                Button("Reveal Terminal", action: selected(revealTerminal))
            case .completed where node.kind == .step:
                Button("Open Artifact", action: selected(openArtifact))
            case .failed where node.kind == .step:
                Button("Open Evidence", action: selected(openEvidence))
                Button("Retry Failed Step", action: selected(retryFailedStep))
            case .interrupted where node.kind == .step:
                Button("Retry Step", action: selected(retryInterruptedStep))
                Button("Abort Run", role: .destructive, action: selected(abortInterruptedRun))
                if hasWorktree {
                    Button("Keep Worktree", action: selected(keepInterruptedWorktree))
                }
            case .awaitingGate where node.kind == .gate:
                Button("Approve Gate", action: selected(approveGate))
                Button("Revise Gate Artifact", action: selected(reviseGate))
                Button("Abort Run", role: .destructive, action: selected(abortGate))
            case .mergeGate where node.kind == .gate:
                Button("Open First Diff", action: selected(openMergeDiff))
                    .disabled(!hasMergeDiff)
                Button("Apply to Workspace", action: selected(applyMerge))
                Button("Discard Worktree", role: .destructive, action: selected(discardMerge))
            default:
                EmptyView()
            }
        }
    }

    private var hasWorktree: Bool {
        guard let runID = node.runID else { return false }
        return session.conductorRuns.first(where: { $0.id == runID })?.worktreeBranch.isEmpty
            == false
    }

    private var hasMergeDiff: Bool {
        guard let runID = node.runID else { return false }
        return session.workflowController(forRunID: runID)?.mergeGateFiles.isEmpty == false
    }

    private func selected(_ action: @escaping () -> Void) -> () -> Void {
        {
            select()
            action()
        }
    }
}

private struct ProviderBadge: View {
    let provider: ConductorCLIID?
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            FileIconView(icon: icon, size: 14)
                .accessibilityHidden(true)
            Text(provider?.displayName ?? "Unknown")
                .font(.caption2)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.palette.chipBackground)
        .clipShape(Capsule())
        .help(provider?.displayName ?? "Unknown provider")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Provider \(provider?.displayName ?? "Unknown")")
    }

    private var icon: FileIconProvider.Icon {
        provider.map(ConductorCLIIcons.icon(for:))
            ?? FileIconProvider.Icon(symbol: "terminal", tint: .secondary)
    }
}

private struct ConductorGraphRefreshInput: Equatable, Sendable {
    let manifests: [ConductorRunManifest]
    let liveStates: [ConductorGraphLiveStateInput]
    let coordinators: [CoordinatorNodeInput]
}

private struct ConductorGraphLiveStateInput: Equatable, Sendable {
    let runID: String
    let state: ConductorWorkflowState
}

private struct ConductorGraphLayout: Sendable {
    static let nodeSize = CGSize(width: 292, height: 222)
    private static let horizontalGap: CGFloat = 84
    private static let verticalGap: CGFloat = 36
    private static let inset: CGFloat = 32

    let size: CGSize
    private let centers: [String: CGPoint]

    init(graph: ConductorGraph) {
        var centers: [String: CGPoint] = [:]
        for node in graph.nodes {
            centers[node.id] = CGPoint(
                x: Self.inset + Self.nodeSize.width / 2
                    + CGFloat(node.column) * (Self.nodeSize.width + Self.horizontalGap),
                y: Self.inset + Self.nodeSize.height / 2
                    + CGFloat(node.row) * (Self.nodeSize.height + Self.verticalGap))
        }
        self.centers = centers
        size = CGSize(
            width: Self.inset * 2 + CGFloat(max(graph.columnCount, 1)) * Self.nodeSize.width
                + CGFloat(max(graph.columnCount - 1, 0)) * Self.horizontalGap,
            height: Self.inset * 2 + CGFloat(max(graph.rowCount, 1)) * Self.nodeSize.height
                + CGFloat(max(graph.rowCount - 1, 0)) * Self.verticalGap)
    }

    func center(of id: String) -> CGPoint? {
        centers[id]
    }

    func trailingEdge(of id: String) -> CGPoint? {
        centers[id].map {
            CGPoint(x: $0.x + Self.nodeSize.width / 2, y: $0.y)
        }
    }

    func leadingEdge(of id: String) -> CGPoint? {
        centers[id].map {
            CGPoint(x: $0.x - Self.nodeSize.width / 2, y: $0.y)
        }
    }
}
