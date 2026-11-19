import Dispatch
import Foundation
import Synchronization

/// Carries one terminal's Codex requests between the proxy and the app.
///
/// The proxy hands over each approval or question for the bound thread. The
/// supervisor opens it in the app (`approvalOpen`), polls for the user's answer
/// every 500 ms while any request waits (`approvalPoll`), gives the answer back
/// to the proxy to write on the TUI's own connection, and closes the request in
/// the app (`approvalClose`) once it is gone for any reason.
///
/// Every app call runs on one private serial queue, so an open and the close
/// that follows it never swap places, and the relay threads never wait on the
/// app. Request text, answers and JSON-RPC IDs are never logged; the app sees
/// only the opaque key.
final class CanvasCodexApprovalSupervisor: Sendable {
    typealias Exchange = @Sendable (CanvasBridgeRequest) throws -> CanvasBridgeResponse

    private struct State {
        var stopped = false
        /// Keys opened in the app and not yet closed.
        var open: Set<UUID> = []
        var timer: (any DispatchSourceTimer)?
        var proxy: CanvasCodexProxy?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "app.rafu.codex-approvals")
    private let exchange: Exchange
    private let token: String
    private let endpoint: String
    private let threadID: String
    private let interval: DispatchTimeInterval

    init(
        token: String, endpoint: String, threadID: String,
        interval: DispatchTimeInterval = .milliseconds(500), exchange: @escaping Exchange
    ) {
        self.token = token
        self.endpoint = endpoint
        self.threadID = threadID
        self.interval = interval
        self.exchange = exchange
    }

    /// What the proxy calls. Both only enqueue work.
    var hooks: CanvasCodexProxy.Approvals {
        CanvasCodexProxy.Approvals(
            request: { [self] request in queue.async { self.open(request) } },
            clear: { [self] key in queue.async { self.close(key) } })
    }

    /// The proxy that writes the answers. The supervisor holds it until `stop()`.
    func attach(_ proxy: CanvasCodexProxy) {
        state.withLock { $0.proxy = proxy }
    }

    /// Stops polling and drops the proxy. Later hooks do nothing.
    func stop() {
        let timer = state.withLock { state -> (any DispatchSourceTimer)? in
            state.stopped = true
            state.proxy = nil
            state.open.removeAll()
            defer { state.timer = nil }
            return state.timer
        }
        timer?.cancel()
    }

    /// True while the poll timer runs. For tests.
    var isPolling: Bool { state.withLock { $0.timer != nil } }

    /// Returns once every queued call has run. For tests.
    func settle() { queue.sync {} }

    // MARK: Work on the queue

    private func open(_ request: CanvasAgentRequest) {
        let accepted = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.open.insert(request.key)
            return true
        }
        guard accepted else { return }
        let sent = try? exchange(bridgeRequest(CanvasAgentRequest.openOperation, approval: request))
        guard let sent, sent.error == nil else {
            // The app did not take it. The terminal prompt still works.
            _ = state.withLock { $0.open.remove(request.key) }
            stopTimerIfIdle()
            return
        }
        startTimer()
    }

    private func close(_ key: UUID) {
        let known = state.withLock { $0.open.remove(key) != nil }
        guard known else { return }
        // Best effort: the app also clears a terminal's requests on release.
        _ = try? exchange(bridgeRequest(CanvasAgentRequest.closeOperation, key: key))
        stopTimerIfIdle()
    }

    private func poll() {
        let proxy = state.withLock { state -> CanvasCodexProxy? in
            state.open.isEmpty ? nil : state.proxy
        }
        guard let proxy else {
            stopTimerIfIdle()
            return
        }
        guard
            let answer = (try? exchange(bridgeRequest(CanvasAgentRequest.pollOperation)))?
                .approvalDecision,
            state.withLock({ $0.open.contains(answer.key) })
        else { return }
        // The app keeps its answer until closed, so every outcome except a
        // busy connection ends with a close.
        if proxy.inject(key: answer.key, decision: answer.decision) == .busy { return }
        close(answer.key)
    }

    private func startTimer() {
        // Created, scheduled and resumed under the lock, so `stop()` never
        // cancels a source that was not resumed yet.
        state.withLock { state in
            guard !state.stopped, state.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
            timer.setEventHandler { [self] in poll() }
            timer.resume()
            state.timer = timer
        }
    }

    private func stopTimerIfIdle() {
        let timer = state.withLock { state -> (any DispatchSourceTimer)? in
            guard state.open.isEmpty else { return nil }
            defer { state.timer = nil }
            return state.timer
        }
        timer?.cancel()
    }

    private func bridgeRequest(
        _ operation: String, approval: CanvasAgentRequest? = nil, key: UUID? = nil
    ) -> CanvasBridgeRequest {
        CanvasBridgeRequest(
            token: token, operation: operation, provider: "codex", threadID: threadID,
            endpoint: endpoint, approval: approval, approvalKey: key)
    }
}
