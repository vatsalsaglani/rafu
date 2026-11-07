import Foundation
import RafuCore

/// The GPT-Live protocol over one transport. Decoding happens here, off the
/// main actor; the session sees typed events only. Nothing here logs.
actor VoiceLiveClient {
    nonisolated let events: AsyncStream<VoiceLiveServerEvent>
    private let continuation: AsyncStream<VoiceLiveServerEvent>.Continuation
    private let transport: any VoiceLiveTransport
    private let closeTimeout: Duration
    private var pump: Task<Void, Never>?
    private var isClosed = false
    private var receivedClosed = false
    private var closeWaiter: CheckedContinuation<Void, Never>?

    init(transport: any VoiceLiveTransport, closeTimeout: Duration = .seconds(15)) {
        self.transport = transport
        self.closeTimeout = closeTimeout
        (events, continuation) = AsyncStream.makeStream(
            of: VoiceLiveServerEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Opens the socket and starts reading. The read loop belongs to this
    /// client and ends with the transport.
    func start() async throws {
        guard !isClosed else { throw VoiceError.disconnected }
        try await transport.connect()
        guard !isClosed, pump == nil else { return }
        pump = Task { await self.read() }
    }

    private func read() async {
        for await text in transport.incoming {
            guard let event = VoiceLiveServerEvent.decode(text) else { continue }
            if case .sessionClosed = event {
                receivedClosed = true
                resumeCloseWaiter()
            }
            continuation.yield(event)
        }
        // The socket is gone: a close in progress need not wait any longer.
        receivedClosed = true
        resumeCloseWaiter()
        continuation.finish()
    }

    func send(_ event: VoiceLiveClientEvent) async throws {
        guard !isClosed else { throw VoiceError.disconnected }
        let text = try event.json()
        try await transport.send(text)
    }

    /// Sends `session.close` and waits for `session.closed` (Phase 0: 0.5–1 s)
    /// for at most `closeTimeout`, then drops the socket. Safe to call twice.
    func close() async {
        guard !isClosed else { return }
        if !receivedClosed, (try? await send(.sessionClose)) != nil {
            await waitForClosed()
        }
        isClosed = true
        transport.cancel()
        pump?.cancel()
        pump = nil
        continuation.finish()
    }

    /// Drops the socket at once, for a failure.
    func cancel() {
        isClosed = true
        transport.cancel()
        pump?.cancel()
        pump = nil
        resumeCloseWaiter()
        continuation.finish()
    }

    private func waitForClosed() async {
        guard !receivedClosed else { return }
        let timeout = closeTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            self.resumeCloseWaiter()
        }
        await withCheckedContinuation { waiter in
            if receivedClosed { waiter.resume() } else { closeWaiter = waiter }
        }
        timer.cancel()
    }

    private func resumeCloseWaiter() {
        let waiter = closeWaiter
        closeWaiter = nil
        waiter?.resume()
    }
}
