import Foundation
import Observation
import RafuCore

/// The open Claude Code permission requests that Rafu shows in Up next, and
/// the rules that end them. A value type with no I/O, so tests drive it with
/// a fixed clock.
nonisolated struct ClaudeAnswerRequestBook: Equatable, Sendable {
    /// One waiting helper, shown for one Rafu terminal.
    struct Entry: Equatable, Sendable {
        /// The hook event id: the request key and the answer file name.
        let eventID: UUID
        let controllerID: UUID
        let sessionID: String
        /// Set when a sub-agent asked. Only events of the same sub-agent (or
        /// of the main agent, for nil) end the request.
        let subagentID: String?
        let toolName: String?
        let receivedAt: Date
        /// The helper stops waiting by itself at this time.
        let expiresAt: Date
        /// A helper waits for this request, so ending it writes `dismiss`.
        /// False for a plan, a notice and an unclassified request: they are
        /// only shown, and nobody reads an answer file for them.
        let waits: Bool
    }

    /// Seconds. The helper gives up after `AgentAnswerChannel.waitSeconds`,
    /// so a request is gone then whatever happened.
    static let lifetime = TimeInterval(AgentAnswerChannel.waitSeconds)

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    func entry(eventID: UUID) -> Entry? {
        entries.first { $0.eventID == eventID }
    }

    mutating func add(_ event: AgentHookEvent, controllerID: UUID) {
        guard entry(eventID: event.id) == nil else { return }
        entries.append(
            Entry(
                eventID: event.id, controllerID: controllerID, sessionID: event.sessionID,
                subagentID: event.subagentID, toolName: event.toolName, receivedAt: event.time,
                expiresAt: event.time.addingTimeInterval(Self.lifetime),
                waits: ClaudePermissionAnswerBridge.helperWaits(event)))
    }

    /// True when a request of `sessionID` is open (any sub-agent).
    func hasEntry(sessionID: String) -> Bool {
        entries.contains { $0.sessionID == sessionID }
    }

    @discardableResult
    mutating func remove(eventID: UUID) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.eventID == eventID }) else { return nil }
        return entries.remove(at: index)
    }

    mutating func removeAll() -> [Entry] {
        defer { entries = [] }
        return entries
    }

    /// Removes and returns the entries that `event` shows as done: the tool
    /// ran or failed, the turn ended or a new one started, the session
    /// ended, or Claude asked the next permission question (Claude shows
    /// the next dialog only after the earlier one is answered). The same
    /// rules end a question set (AskUserQuestion), a plan (ExitPlanMode) and
    /// a notice; a notice has no tool, so any tool that finishes ends it.
    mutating func resolve(by event: AgentHookEvent) -> [Entry] {
        let done = entries.filter { Self.resolves(event, $0) }
        guard !done.isEmpty else { return [] }
        let ids = Set(done.map(\.eventID))
        entries.removeAll { ids.contains($0.eventID) }
        return done
    }

    /// Removes and returns the entries whose helper stopped waiting.
    mutating func expire(now: Date) -> [Entry] {
        let done = entries.filter { now >= $0.expiresAt }
        guard !done.isEmpty else { return [] }
        entries.removeAll { now >= $0.expiresAt }
        return done
    }

    /// Whether `event`, from the same Claude Code session, ends `entry`.
    /// Pure; the event names are Claude Code's hook names.
    static func resolves(_ event: AgentHookEvent, _ entry: Entry) -> Bool {
        guard event.provider == .claude, event.sessionID == entry.sessionID,
            event.id != entry.eventID, event.time >= entry.receivedAt
        else { return false }
        // The whole session ended: every request in it is gone.
        if event.hookEventName == "SessionEnd", event.subagentID == nil { return true }
        guard event.subagentID == entry.subagentID else { return false }
        switch event.hookEventName {
        case "PostToolUse", "PostToolUseFailure":
            // A parallel tool of another kind may finish while this one
            // waits, so only the same tool counts.
            return entry.toolName == nil || event.toolName == entry.toolName
        case "UserPromptSubmit", "Stop", "StopFailure", "SubagentStop", "SessionEnd":
            return true
        case "PermissionRequest":
            // The other hook entry writes a second event for the same
            // request, without a summary. Only a new answerable request
            // shows that the earlier dialog closed.
            return ClaudePermissionAnswerBridge.isAnswerable(event)
        default:
            return false
        }
    }
}

/// One write to the answer channel. The coordinator decides; a writer does
/// the file work off the main actor.
nonisolated enum ClaudeAnswerWrite: Equatable, Sendable {
    case submit(CanvasAgentRequestAnswer)
    case dismiss(UUID)
}

/// Answers Claude Code permission requests from the Up next row.
///
/// - Shows every request the answer-mode helper writes: an answerable card,
///   a question set, a read-only plan, or a notice for a request Rafu could
///   not classify (its shape, names and types only, goes to the
///   `AgentRequestShape` log). A Claude Code `Notification` that asks for
///   the person opens a read-only notice when the session has no request
///   open.
///
/// - Holds the `AgentAnswerWatchLock` only while `setWatching(true)`: a held
///   lock makes every answer-mode helper wait, so the owner turns it on only
///   while the person enabled the setting, the answer entry is connected and
///   the spool is drained.
/// - For each drained answerable event, finds the Rafu terminal of the
///   session (`AgentTerminalMatcher`, process chain first). A match opens a
///   request in `AgentRequestStore`; no match, or a store refusal, writes
///   `dismiss` so the helper exits and Claude keeps its own dialog.
/// - Writes the person's answer when the store has one, then closes the
///   request.
/// - Closes the request and writes `dismiss` when the session's next event
///   shows the tool ran or was answered in the terminal, when the request
///   expires, or when its terminal is gone. When something else cleared the
///   request from the store (terminal exit, a new terminal route), it only
///   writes `dismiss`. It writes `dismiss` only for a request whose helper
///   waits.
///
/// Request text never reaches a log.
@MainActor
final class ClaudePermissionAnswerCoordinator {
    typealias Terminals = @MainActor () -> [AgentTerminalCandidate]
    typealias Writer = @MainActor (ClaudeAnswerWrite) -> Void
    typealias ShapeRecorder = @MainActor (String) -> Void

    let channel: AgentAnswerChannel
    private let requests: AgentRequestStore
    private let terminals: Terminals
    private let write: Writer
    private let recordShape: ShapeRecorder
    private let now: @MainActor () -> Date
    private var lock: AgentAnswerWatchLock?
    private(set) var book = ClaudeAnswerRequestBook()
    private var isObserving = false

    /// `write` and `recordShape` are test seams; the default writes off the
    /// main actor and logs each distinct shape once per launch.
    init(
        channel: AgentAnswerChannel,
        requests: AgentRequestStore,
        terminals: @escaping Terminals,
        now: @escaping @MainActor () -> Date = { Date() },
        write: Writer? = nil,
        recordShape: ShapeRecorder? = nil
    ) {
        self.channel = channel
        self.requests = requests
        self.terminals = terminals
        self.now = now
        self.recordShape =
            recordShape ?? { AgentRequestShape.Recorder.shared.record($0) }
        let bridge = ClaudePermissionAnswerBridge(channel: channel)
        self.write = write ?? { change in Task { await ClaudeAnswerIO.perform(change, bridge) } }
    }

    /// True while Rafu holds the watch lock.
    var isWatching: Bool { lock != nil }

    /// Takes or releases the watch lock. Releasing it also ends every open
    /// request: the helpers see the free lock and exit without output.
    func setWatching(_ watching: Bool) {
        if watching {
            guard lock == nil else { return }
            lock = AgentAnswerWatchLock(channel: channel)
        } else {
            guard let held = lock else { return }
            held.release()
            lock = nil
            for entry in book.removeAll() { end(entry) }
        }
    }

    /// App quit: releases the lock and drops every request. Writes nothing;
    /// the free lock tells each helper to stop.
    func stop() {
        lock?.release()
        lock = nil
        for entry in book.removeAll() {
            requests.close(controllerID: entry.controllerID, key: entry.eventID)
        }
    }

    /// Folds drained events, oldest first, then reconciles with the store.
    func handle(_ events: [AgentHookEvent]) {
        let date = now()
        for event in events {
            // Names and types only; the recorder logs each shape once.
            if event.provider == .claude, let shape = event.requestShape { recordShape(shape) }
            for entry in book.resolve(by: event) { end(entry) }
            open(event, at: date)
        }
        reconcile()
    }

    /// Writes chosen answers and drops requests that are gone. Runs after
    /// each drain and each change of the request store.
    func reconcile() {
        let date = now()
        for entry in book.expire(now: date) { end(entry) }
        let live = Set(terminals().map(\.id))
        for entry in book.entries {
            if let decision = requests.decision(for: entry.controllerID, key: entry.eventID) {
                book.remove(eventID: entry.eventID)
                requests.close(controllerID: entry.controllerID, key: entry.eventID)
                write(.submit(CanvasAgentRequestAnswer(key: entry.eventID, decision: decision)))
            } else if !requests.requests(for: entry.controllerID).contains(where: {
                $0.key == entry.eventID
            }) {
                // Cleared by its terminal's exit or route change.
                book.remove(eventID: entry.eventID)
                if entry.waits { write(.dismiss(entry.eventID)) }
            } else if !live.contains(entry.controllerID) {
                book.remove(eventID: entry.eventID)
                end(entry)
            }
        }
        observeRequestsIfNeeded()
    }

    // MARK: Private

    /// Closes `entry`'s request in the store and, when its helper waits,
    /// tells the helper to leave Claude's dialog alone.
    private func end(_ entry: ClaudeAnswerRequestBook.Entry) {
        requests.close(controllerID: entry.controllerID, key: entry.eventID)
        if entry.waits { write(.dismiss(entry.eventID)) }
    }

    private func open(_ event: AgentHookEvent, at date: Date) {
        // The helper writes an answerable event only while the lock is held.
        // Without it, the helper is gone or about to go: nothing to answer.
        guard isWatching, date.timeIntervalSince(event.time) < ClaudeAnswerRequestBook.lifetime,
            book.entry(eventID: event.id) == nil
        else { return }
        let waits = ClaudePermissionAnswerBridge.helperWaits(event)
        let request: CanvasAgentRequest?
        if ClaudePermissionAnswerBridge.isAnswerable(event) {
            request = ClaudePermissionAnswerBridge.request(for: event)
        } else if !book.hasEntry(sessionID: event.sessionID) {
            // A notification for a prompt Rafu shows already adds nothing.
            guard let notice = ClaudePermissionAnswerBridge.notice(for: event) else { return }
            request = notice
        } else {
            return
        }
        guard let request, let controllerID = Self.terminal(for: event, in: terminals()) else {
            if waits { write(.dismiss(event.id)) }
            return
        }
        switch requests.open(request, controllerID: controllerID) {
        case .opened, .alreadyOpen:
            book.add(event, controllerID: controllerID)
        case .conflict, .full:
            if waits { write(.dismiss(event.id)) }
        }
    }

    /// The one live Rafu terminal that runs `event`'s session, or nil. Uses
    /// the shared matcher: the helper's process chain first, the folder only
    /// for an event without a chain. More than one match is no match.
    static func terminal(
        for event: AgentHookEvent, in candidates: [AgentTerminalCandidate]
    ) -> UUID? {
        let probe = TrackedAgentSession(
            provider: event.provider, sessionID: event.sessionID, state: .waitingForPermission,
            cwd: event.cwd, ancestorProcessIDs: event.ancestorProcessIDs, startedAt: event.time)
        let matches = candidates.filter {
            AgentTerminalMatcher.session(for: $0, in: [probe]) != nil
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Reconciles again when the store changes (the person chose an answer,
    /// or a terminal cleared its requests). Only while requests are open.
    private func observeRequestsIfNeeded() {
        guard !book.isEmpty, !isObserving else { return }
        isObserving = true
        withObservationTracking {
            _ = requests.pending
            _ = requests.chosen
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObserving = false
                self.reconcile()
            }
        }
    }
}

/// The coordinator's file work, always off the main actor.
nonisolated enum ClaudeAnswerIO {
    @concurrent
    static func perform(_ change: ClaudeAnswerWrite, _ bridge: ClaudePermissionAnswerBridge)
        async
    {
        switch change {
        case .submit(let answer): _ = bridge.submit(answer)
        case .dismiss(let eventID): bridge.dismiss(eventID: eventID)
        }
    }
}
