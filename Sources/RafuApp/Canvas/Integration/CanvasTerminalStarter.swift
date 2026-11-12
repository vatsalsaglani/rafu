import Foundation

/// One line an agent asked Rafu to type into a terminal node.
struct PendingTerminalLine: Equatable {
    let text: String
    let queuedAt: Date
}

extension CanvasBoardState {
    /// Lines held per node. A shell that is slow to start can take a few
    /// commands in a row, such as `cd` and then an agent launch.
    static let pendingTerminalLineLimit = 8
    /// A queued line that nobody drained in this time is dropped, so a command
    /// an agent asked for is never typed long after the request.
    static let pendingTerminalLineLifetime: TimeInterval = 15 * 60

    /// Adds a line behind the ones already waiting. False when the node
    /// already holds `pendingTerminalLineLimit` lines.
    func queueTerminalLine(_ text: String, for card: CanvasCardID, now: Date = Date()) -> Bool {
        dropExpiredTerminalLines(now: now)
        var lines = pendingTerminalLines[card] ?? []
        guard lines.count < Self.pendingTerminalLineLimit else { return false }
        lines.append(PendingTerminalLine(text: text, queuedAt: now))
        pendingTerminalLines[card] = lines
        return true
    }

    func pendingTerminalLineCount(for card: CanvasCardID) -> Int {
        pendingTerminalLines[card]?.count ?? 0
    }

    func pendingTerminalLineBytes(for card: CanvasCardID) -> Int {
        pendingTerminalLines[card]?.reduce(0) { $0 + $1.text.utf8.count } ?? 0
    }

    /// Hands up to `limit` waiting lines to `send`, oldest first. A line leaves
    /// the queue before it is sent, so two callers never type the same line; a
    /// line that `send` refuses goes back to the front. Returns how many were
    /// typed.
    @discardableResult
    func drainPendingTerminalLines(
        for card: CanvasCardID, now: Date = Date(), limit: Int = .max,
        send: (String) -> Bool
    ) -> Int {
        dropExpiredTerminalLines(now: now)
        var typed = 0
        while typed < limit, let next = pendingTerminalLines[card]?.first {
            pendingTerminalLines[card]?.removeFirst()
            if pendingTerminalLines[card]?.isEmpty == true { pendingTerminalLines[card] = nil }
            guard send(next.text) else {
                pendingTerminalLines[card, default: []].insert(next, at: 0)
                break
            }
            typed += 1
        }
        return typed
    }

    func dropExpiredTerminalLines(now: Date) {
        guard !pendingTerminalLines.isEmpty else { return }
        let oldest = now.addingTimeInterval(-Self.pendingTerminalLineLifetime)
        for (card, lines) in pendingTerminalLines {
            let kept = lines.filter { $0.queuedAt > oldest }
            pendingTerminalLines[card] = kept.isEmpty ? nil : kept
        }
    }

    /// Drops the lines of nodes that are no longer on the board.
    func prunePendingTerminalLines() {
        guard !pendingTerminalLines.isEmpty else { return }
        let present = Set(cards.map(\.id))
        pendingTerminalLines = pendingTerminalLines.filter { present.contains($0.key) }
    }

    func discardPendingTerminalLines() { pendingTerminalLines.removeAll() }
}

/// What a start left behind, for the agent's reply. It holds counts and states,
/// never the line.
struct CanvasTerminalStartReport: Equatable {
    /// Why a stopped node did not start.
    enum Hold: Equatable {
        /// Four Ensemble terminals already hold a live view.
        case leaseCap
        /// The node has no shell to start, or the live-session limit is reached.
        case unavailable
        /// Rafu tried and the terminal manager refused (it shows an alert).
        case refused
    }

    var running = false
    var hold: Hold?
    /// The node already held the most lines it may; this one was not queued.
    var queueFull = false
    var queuedLines = 0
    var queuedBytes = 0
    /// Rafu moved the user's view to show the node.
    var viewMoved = false
}

/// Starts a terminal node for an agent and gets its queued lines typed.
///
/// A process starts only through the card's own view (ADR 0023, ADR 0025): this
/// type never spawns one. It makes the card able to start, asks it to start,
/// waits a bounded time to see whether it did, and queues lines on the board so
/// they survive a shell that is not ready, or a card that is not on screen yet.
enum CanvasTerminalStarter {
    /// The agent's bridge call has a 20 s IPC timeout and Ask can use 12 s of it
    /// (`CanvasAgentCenter.approvalWait`, `LauncherIPCClient.canvasBridgeTimeoutSeconds`).
    /// This wait adds at most 2.5 s.
    nonisolated static let defaultConfirmSteps = 25
    /// Task-local so a test can shorten the wait for its own call tree only.
    @TaskLocal static var confirmSteps = defaultConfirmSteps
    static let step: Duration = .milliseconds(100)

    /// A test seam for the typing task that `start` begins: when readiness and
    /// the send are replaced, a test needs no real shell process. It is task-local
    /// like `confirmSteps`, so it reaches only the call tree that sets it.
    nonisolated struct DrainSeams: Sendable {
        var isReady: @MainActor @Sendable (WorkspaceTerminalController) -> Bool
        var send: @MainActor @Sendable (WorkspaceTerminalController, String) -> Bool
    }
    @TaskLocal static var drainSeams: DrainSeams? = nil
    /// After the shell process appears, typing waits this many steps for the
    /// shell to reach its line editor. Input the tty buffered earlier can be lost
    /// while the shell sets up, or echoed twice: once by the tty in cooked mode
    /// and again by the line editor. This holds for a bridge terminal too.
    static let settleSteps = 5
    /// The terminal must have printed nothing for this long before a line is
    /// typed: a shell still printing its startup output is not at its prompt.
    static let quietInterval: TimeInterval = 0.3
    /// A terminal that never goes quiet (an agent at work redraws a spinner)
    /// gets its line this many steps after its process appeared, quiet or not.
    static let quietWaitSteps = 20
    /// The typing wait is ten seconds, off the reply path.
    static let drainSteps = 100
    /// Mirrors the presentation lease cap in `CanvasTerminalCard.acquire`.
    static let leaseCap = 4

    /// Starts the node and queues its `line`, so a later start still types it.
    ///
    /// When a card view can host the terminal (its board is on screen and the
    /// window is visible), this reveals the node, asks the card to start, and
    /// waits up to `confirmSteps` for the pane to go live. Otherwise it starts the
    /// pane itself and creates its terminal view without mounting it
    /// (`startInBackground`), so a permitted start never waits for the user. A
    /// card that the user shows later reuses the same view.
    static func start(
        card: CanvasCard, groupID: TerminalGroupID, line: String?, board: CanvasBoardState,
        session: WorkspaceSession, onGiveUp: @escaping @MainActor () -> Void
    ) async throws -> CanvasTerminalStartReport {
        guard let first = pane(groupID, session) else { throw CanvasError.unavailable }
        var report = CanvasTerminalStartReport()
        if let line, !board.queueTerminalLine(line, for: card.id) {
            report.queueFull = true
            report.running = first.status == .live
            count(&report, card: card.id, board: board)
            return report
        }
        let viewBefore = board.viewport
        let hosted = canHostView(board, session)
        if first.status == .live {
            if board.pendingTerminalLineCount(for: card.id) > 0, !isTypeable(first, session) {
                if hosted {
                    reveal(card, board)
                } else {
                    session.hostCanvasTerminalView(first.id)
                }
            }
        } else if !canStart(first) {
            report.hold = .unavailable
        } else if !hosted {
            startInBackground(first, session, &report)
        } else if leaseBlocked(groupID, session) {
            report.hold = .leaseCap
        } else {
            reveal(card, board)
            let asked = await requestStart(card, groupID, board, session, &report)
            // The card took the request and still did not start (it could not
            // take the view, for example). Start the pane without it.
            if asked, report.hold == nil, board.terminalStartRequest != card.id,
                let latest = pane(groupID, session), latest.status != .live, canStart(latest),
                !Task.isCancelled
            {
                startInBackground(latest, session, &report)
            }
        }
        if let latest = pane(groupID, session), latest.status == .live {
            report.running = true
            report.hold = nil
        } else if report.hold == nil, leaseBlocked(groupID, session) {
            report.hold = .leaseCap
        }
        report.viewMoved = board.viewport != viewBefore
        count(&report, card: card.id, board: board)
        if report.running {
            startDrain(card.id, groupID, board, session, onGiveUp: onGiveUp)
        }
        return report
    }

    /// Types the queued lines once the shell runs. One loop per node. Returns
    /// true when the queue is empty; lines left after a timeout or a stopped
    /// view stay queued for the next drain.
    ///
    /// A line is typed when the process has run for `settle` steps and the
    /// terminal is quiet (`isQuiet`), or once it has run for `quietWait` steps.
    /// One line per step, and never while the previous line's Return is still
    /// owed (`isReturnPending`): `sendReply` writes the Return 250 ms after the
    /// text, so the next line's text never comes right after an early Return.
    @discardableResult
    static func drain(
        card: CanvasCardID, groupID: TerminalGroupID, board: CanvasBoardState,
        session: WorkspaceSession, settle: Int = settleSteps, quietWait: Int = quietWaitSteps,
        isReady: (WorkspaceTerminalController) -> Bool = {
            $0.isProcessRunning && !$0.isReturnPending
        },
        isQuiet: (WorkspaceTerminalController) -> Bool = {
            ($0.secondsSinceLastOutput ?? 0) >= quietInterval
        },
        send: (WorkspaceTerminalController, String) -> Bool = { $0.sendReply($1) }
    ) async -> Bool {
        guard board.terminalLineDrains.insert(card).inserted else { return false }
        defer { board.terminalLineDrains.remove(card) }
        var runningSince: Int?
        for step in 0..<drainSteps {
            if board.pendingTerminalLines[card] == nil { return true }
            guard board.cards.contains(where: { $0.id == card }),
                session.canvas.boards[board.id] != nil,
                let current = pane(groupID, session)
            else {
                board.pendingTerminalLines[card] = nil
                return false
            }
            if current.status == .live,
                let controller = session.terminal.terminalController(for: current.id),
                isReady(controller)
            {
                let since = runningSince ?? step
                runningSince = since
                let running = step - since
                if running >= quietWait || (running >= settle && isQuiet(controller)) {
                    board.drainPendingTerminalLines(for: card, limit: 1) { send(controller, $0) }
                    if board.pendingTerminalLines[card] == nil { return true }
                }
            } else {
                runningSince = nil
            }
            do { try await Task.sleep(for: Self.step) } catch { return false }
        }
        return false
    }

    /// Runs `drain` in its own task when lines wait and no loop runs for the node.
    static func startDrain(
        _ card: CanvasCardID, _ groupID: TerminalGroupID, _ board: CanvasBoardState,
        _ session: WorkspaceSession, onGiveUp: @escaping @MainActor () -> Void
    ) {
        guard board.pendingTerminalLines[card] != nil, !board.terminalLineDrains.contains(card)
        else { return }
        let seams = drainSeams
        Task(name: "Type queued lines into Ensemble terminal") { [weak session, weak board] in
            guard let session, let board else { return }
            if let seams {
                await drain(
                    card: card, groupID: groupID, board: board, session: session, settle: 0,
                    isReady: seams.isReady, isQuiet: { _ in true }, send: seams.send)
            } else {
                await drain(card: card, groupID: groupID, board: board, session: session)
            }
            if board.pendingTerminalLines[card] != nil { onGiveUp() }
        }
    }

    // MARK: Steps

    /// Asks the card to start, again when it took the request and did not start
    /// (the lease was not ready), but not more than three times: every refused
    /// start by the terminal manager shows an alert.
    /// The result is true when the request was set at least once.
    private static func requestStart(
        _ card: CanvasCard, _ groupID: TerminalGroupID, _ board: CanvasBoardState,
        _ session: WorkspaceSession, _ report: inout CanvasTerminalStartReport
    ) async -> Bool {
        let alertBefore = session.isTerminalGroupErrorPresented
        var asks = 0
        for index in 0..<confirmSteps {
            guard let current = pane(groupID, session), current.status != .live else {
                return asks > 0
            }
            if session.isTerminalGroupErrorPresented, !alertBefore {
                report.hold = .refused
                return asks > 0
            }
            // Another card's pending request is never overwritten.
            if index.isMultiple(of: 5), asks < 3,
                board.terminalStartRequest == nil || board.terminalStartRequest == card.id
            {
                board.terminalStartRequest = card.id
                asks += 1
            }
            if Task.isCancelled { return asks > 0 }
            do { try await Task.sleep(for: step) } catch { return asks > 0 }
        }
        return asks > 0
    }

    /// True when a mounted card can start the node and show its view: the board
    /// is the visible tab and its window is not hidden. Otherwise no card view
    /// exists to consume a start request.
    private static func canHostView(_ board: CanvasBoardState, _ session: WorkspaceSession)
        -> Bool
    {
        session.canvasResources[board.id]?.permitsLiveContent == true
    }

    /// Starts the pane without a card: the terminal view is created but not
    /// mounted, so the shell runs while the board is in the background. No lease
    /// is taken, the user's view does not move, and a card that mounts later
    /// attaches to the same view. The node still exists on the board.
    private static func startInBackground(
        _ pane: TerminalPaneSnapshot, _ session: WorkspaceSession,
        _ report: inout CanvasTerminalStartReport
    ) {
        let alertBefore = session.isTerminalGroupErrorPresented
        if pane.status == .exited {
            session.restartTerminalPaneInBackground(pane.id)
        } else {
            session.startTerminalPane(pane.id, background: true)
        }
        if session.isTerminalGroupErrorPresented, !alertBefore { report.hold = .refused }
    }

    /// Before a start: a view-only card in a zoomed-out board is not mounted, so
    /// its Start never runs. Zoom in to it, or pan it into view at the current zoom.
    private static func reveal(_ card: CanvasCard, _ board: CanvasBoardState) {
        if CanvasZoomFace(scale: board.viewport.scale).showsLiveContent {
            board.revealCard(card.id)
        } else {
            board.zoomToCard(card.id)
        }
    }

    private static func count(
        _ report: inout CanvasTerminalStartReport, card: CanvasCardID, board: CanvasBoardState
    ) {
        report.queuedLines = board.pendingTerminalLineCount(for: card)
        report.queuedBytes = board.pendingTerminalLineBytes(for: card)
    }

    private static func pane(_ groupID: TerminalGroupID, _ session: WorkspaceSession)
        -> TerminalPaneSnapshot?
    {
        session.terminal.terminalGroup(groupID)?.panes.first
    }

    private static func isTypeable(_ pane: TerminalPaneSnapshot, _ session: WorkspaceSession)
        -> Bool
    {
        pane.status == .live
            && session.terminal.terminalController(for: pane.id)?.isProcessRunning == true
    }

    private static func canStart(_ pane: TerminalPaneSnapshot) -> Bool {
        (pane.status == .stopped && pane.startAvailability == .available)
            || (pane.status == .exited && pane.runtimeKind == .ordinaryShell)
    }

    /// True when the node cannot get a presentation lease. A lease held by a
    /// terminal that is not live is released first, so stopped nodes never
    /// fill the cap.
    private static func leaseBlocked(
        _ groupID: TerminalGroupID, _ session: WorkspaceSession
    ) -> Bool {
        guard session.canvasTerminalOwners[groupID] == nil,
            session.canvasTerminalOwners.count >= leaseCap
        else { return false }
        session.releaseIdleCanvasTerminalLeases()
        return session.canvasTerminalOwners.count >= leaseCap
    }
}

extension WorkspaceSession {
    /// Gives the presentation lease (ADR 0025) of `groupID` to `board`, within
    /// the cap of `CanvasTerminalStarter.leaseCap` (ADR 0023). At the cap, the
    /// leases of terminals that are not live are released first. True when
    /// `board` holds the lease after the call.
    @discardableResult
    func claimCanvasTerminalLease(_ groupID: TerminalGroupID, for board: CanvasID) -> Bool {
        if canvasTerminalOwners[groupID] == board { return true }
        guard canvasTerminalOwners[groupID] == nil else { return false }
        if canvasTerminalOwners.count >= CanvasTerminalStarter.leaseCap {
            releaseIdleCanvasTerminalLeases()
        }
        guard canvasTerminalOwners.count < CanvasTerminalStarter.leaseCap else { return false }
        canvasTerminalOwners[groupID] = board
        return true
    }

    /// Releases the leases of terminals whose pane is not live (stopped,
    /// exited, unavailable) or whose group is gone. Their cards show the
    /// Start or Restart block, which needs no view; a card takes a lease again
    /// before it starts.
    func releaseIdleCanvasTerminalLeases() {
        for groupID in canvasTerminalOwners.keys
        where terminal.terminalGroup(groupID)?.panes.first?.status != .live {
            canvasTerminalOwners[groupID] = nil
        }
    }
}
