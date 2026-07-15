import Foundation

/// Byte-level transport used by `JSONRPCConnection` to reach a language
/// server, whether over stdio (`LanguageServerProcessTransport`) or an
/// in-memory test double. Speaks only `Data` — framing and JSON-RPC
/// semantics live entirely above this boundary.
nonisolated protocol LanguageServerTransport: Sendable {
    /// Writes `data` to the peer. Throws if the transport is closed or the
    /// underlying write fails.
    func send(_ data: Data) async throws

    /// Returns the stream of inbound byte chunks. Single-consumer: callers
    /// must call this once per transport instance and consume it with one
    /// reader. The stream finishes normally on EOF and throws on a
    /// transport failure. Conforming transports are not required to
    /// support multiple concurrent readers — a second `receive()` call may
    /// return a stream that is already finished.
    func receive() async -> AsyncThrowingStream<Data, any Error>

    /// Idempotent teardown. Safe to call multiple times and safe to call
    /// even if `send`/`receive` were never used.
    func close() async
}
