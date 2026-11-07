import Foundation
import RafuCore

/// One GPT-Live socket: text frames in both directions. Tests replace it with
/// a scripted fake; nothing in the voice tests touches the network.
nonisolated protocol VoiceLiveTransport: Sendable {
    func connect() async throws
    func send(_ text: String) async throws
    /// Server messages in order. Finishes when the socket closes or fails.
    var incoming: AsyncStream<String> { get }
    func cancel()
}

/// `URLSessionWebSocketTask` with an ephemeral session and the key in the
/// `Authorization` header only. This is the one file in `Voice/` that touches
/// the header. Nothing here logs a frame.
nonisolated final class URLSessionWebSocketTransport: VoiceLiveTransport {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    let incoming: AsyncStream<String>

    init(apiKey: String, endpoint: URL = URL(string: VoiceLiveModel.endpoint)!) {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        // A GPT-Live session start echoes the full configuration; the default
        // 1 MiB limit is enough, but say so explicitly.
        task.maximumMessageSize = 4 * 1_024 * 1_024
        self.session = session
        self.task = task
        // Pull-driven: each `next()` of the single consumer awaits one
        // `receive()`. No receive task exists, so nothing outlives the
        // consumer; a transport error ends the stream.
        incoming = AsyncStream(
            unfolding: {
                do {
                    switch try await task.receive() {
                    case .string(let text): return text
                    case .data(let data): return String(decoding: data, as: UTF8.self)
                    @unknown default: return ""
                    }
                } catch {
                    return nil
                }
            },
            onCancel: { task.cancel(with: .goingAway, reason: nil) })
    }

    func connect() async throws { task.resume() }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
