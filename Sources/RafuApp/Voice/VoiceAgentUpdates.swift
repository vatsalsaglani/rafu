import Foundation
import Observation
import RafuCore

/// Where Voice reads agent activity. The live source is the hook-based
/// `AgentActivityStore`; tests give a double.
struct VoiceAgentActivitySource {
    /// Read inside `withObservationTracking`: it must touch only the counter
    /// that moves when an agent ends a turn or starts waiting.
    var revision: @MainActor () -> Int
    /// One signal per terminal card of the board that has a tracked agent.
    var signals: @MainActor (VoiceTarget) -> [VoiceAgentSignal]

    static let live = VoiceAgentActivitySource(
        revision: { AgentActivityStore.shared.replyRevision },
        signals: { target in
            guard let board = target.board else { return [] }
            let store = AgentActivityStore.shared
            var result: [VoiceAgentSignal] = []
            for card in board.cards {
                guard
                    let controller = VoiceTerminalTail.controller(
                        for: card, session: target.session),
                    let tracked = store.trackedSession(for: controller)
                else { continue }
                result.append(
                    VoiceAgentSignal(
                        cardID: card.id.rawValue.uuidString, title: card.title,
                        agent: tracked.provider.displayName, sessionRowID: tracked.rowID,
                        state: tracked.state, replyEventID: tracked.replyEventID,
                        preview: tracked.lastMessagePreview))
            }
            return result
        })
}

/// Watches agent activity while one voice session is open and queues what
/// Rafu should say. It never speaks itself: `VoiceSession` asks for the next
/// sentence when its own gates allow. No polling: `withObservationTracking`
/// re-armed after each change; `stop` ends it.
@MainActor
final class VoiceAgentUpdates {
    private let source: VoiceAgentActivitySource
    private let target: () -> VoiceTarget?
    private let elapsed: () -> Duration
    private let onChange: () -> Void
    private(set) var policy = VoiceAgentUpdatePolicy()
    /// Card id → the announcement key already queued or spoken.
    private var announced: [String: String] = [:]
    private var boardID: CanvasID?
    private var isRunning = false
    private var token = 0

    static let maximumRemembered = 256

    /// `onChange` runs after a change queued something new.
    init(
        source: VoiceAgentActivitySource, target: @escaping () -> VoiceTarget?,
        elapsed: @escaping () -> Duration, onChange: @escaping () -> Void
    ) {
        self.source = source
        self.target = target
        self.elapsed = elapsed
        self.onChange = onChange
    }

    /// Takes the current state as the baseline (replies that exist now are
    /// not announced) and starts observing.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        token += 1
        scan(announce: false)
        arm()
    }

    func stop() {
        isRunning = false
        token += 1
        announced = [:]
        boardID = nil
        policy = VoiceAgentUpdatePolicy()
    }

    func nextSentence(at now: Duration) -> String? { policy.nextSentence(at: now) }

    /// Drops what waits. Used while the Settings toggle is off.
    func discardQueued() {
        if !policy.queue.isEmpty { policy = VoiceAgentUpdatePolicy() }
    }

    private func arm() {
        guard isRunning else { return }
        let armedToken = token
        let revision = source.revision
        withObservationTracking {
            _ = revision()
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed(armedToken) }
        }
    }

    private func changed(_ armedToken: Int) {
        guard isRunning, armedToken == token else { return }
        if scan(announce: true) { onChange() }
        arm()
    }

    /// Compares the board's agents with what was announced. Returns whether
    /// an update was queued. A scan on another board than the last one only
    /// sets the baseline.
    @discardableResult
    func scan(announce: Bool) -> Bool {
        guard let target = target(), let board = target.board else { return false }
        let baselineOnly = !announce || boardID != board.id
        boardID = board.id
        var queued = false
        for signal in source.signals(target) {
            guard let key = signal.announcementKey, let kind = signal.kind else {
                announced[signal.cardID] = nil
                continue
            }
            guard announced[signal.cardID] != key else { continue }
            announced[signal.cardID] = key
            guard !baselineOnly else { continue }
            policy.enqueue(
                VoiceAgentUpdate(
                    cardID: signal.cardID, kind: kind, agent: signal.agent, title: signal.title,
                    excerpt: kind == .done
                        ? VoiceAgentUpdatePolicy.spokenExcerpt(signal.preview) : nil,
                    queuedAt: elapsed()))
            queued = true
        }
        if announced.count > Self.maximumRemembered { announced = [:] }
        return queued
    }
}
