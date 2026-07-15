import Foundation

@testable import RafuApp

/// A cross-wired pair of in-memory `LanguageServerTransport`s for testing
/// `JSONRPCConnection` without a real process: `client.send` yields bytes
/// into `server`'s `receive()` stream and vice versa.
actor InMemoryLanguageServerTransport: LanguageServerTransport {
    private let incomingStream: AsyncThrowingStream<Data, any Error>
    private let peerContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var isClosed = false

    private init(
        incomingStream: AsyncThrowingStream<Data, any Error>,
        peerContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        self.incomingStream = incomingStream
        self.peerContinuation = peerContinuation
    }

    /// Builds a connected pair. Wiring happens entirely inside `init` (no
    /// asynchronous peer-assignment step), so both ends are usable the
    /// instant this returns.
    static func makePair() -> (
        client: InMemoryLanguageServerTransport, server: InMemoryLanguageServerTransport
    ) {
        let (clientToServer, clientToServerContinuation) =
            AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
        let (serverToClient, serverToClientContinuation) =
            AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
        let client = InMemoryLanguageServerTransport(
            incomingStream: serverToClient,
            peerContinuation: clientToServerContinuation
        )
        let server = InMemoryLanguageServerTransport(
            incomingStream: clientToServer,
            peerContinuation: serverToClientContinuation
        )
        return (client, server)
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw InMemoryLanguageServerTransportError.closed }
        peerContinuation.yield(data)
    }

    func receive() async -> AsyncThrowingStream<Data, any Error> {
        incomingStream
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        peerContinuation.finish()
    }
}

nonisolated enum InMemoryLanguageServerTransportError: Error, Equatable {
    case closed
}
