import Foundation
import Synchronization

/// How the installer fetches one model file. Injected, so tests never use the
/// network: production uses `URLSessionMeetingModelTransport`; tests use a
/// fake that writes bytes they choose.
nonisolated protocol MeetingModelTransport: Sendable {
    /// Writes the body of `url` into a new file at `destination` (the parent
    /// folder exists). Stops the transfer and throws
    /// `MeetingModelTransportError.tooLarge` as soon as more than
    /// `maximumBytes` arrive. Calls `onBytes` with each count of new bytes.
    /// Throws `CancellationError` when the calling task is cancelled.
    func download(
        from url: URL, to destination: URL, maximumBytes: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws
}

nonisolated enum MeetingModelTransportError: Error, Equatable, Sendable {
    /// More bytes than the catalog size arrived (or the server announced more).
    case tooLarge
    /// The server answered with a status other than 200.
    case httpStatus(Int)
    /// The transfer failed (no network, a reset connection).
    case transferFailed
    /// The file could not be written.
    case diskWrite
}

/// The production transport: one ephemeral `URLSession` data task for each
/// file, written to disk as the bytes arrive, so a size limit can stop the
/// transfer at once. It never logs the URL.
nonisolated struct URLSessionMeetingModelTransport: MeetingModelTransport {
    func download(
        from url: URL, to destination: URL, maximumBytes: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard
            FileManager.default.createFile(
                atPath: destination.path(percentEncoded: false), contents: nil,
                attributes: [.posixPermissions: 0o600])
        else { throw MeetingModelTransportError.diskWrite }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw MeetingModelTransportError.diskWrite
        }
        defer { try? handle.close() }

        let delegate = MeetingModelTransferDelegate(
            handle: handle, maximumBytes: maximumBytes, onBytes: onBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The session keeps a strong reference to its delegate until it is
        // invalidated.
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: url))

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                delegate.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// The delegate of one transfer. Its callbacks run on the session's serial
/// delegate queue; the state is behind a `Mutex`.
nonisolated final class MeetingModelTransferDelegate: NSObject, URLSessionDataDelegate,
    Sendable
{
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var received: Int64 = 0
        var failure: MeetingModelTransportError?
        var finished = false
    }

    private let handle: FileHandle
    private let maximumBytes: Int64
    private let onBytes: @Sendable (Int64) -> Void
    private let state = Mutex(State())

    init(handle: FileHandle, maximumBytes: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.maximumBytes = maximumBytes
        self.onBytes = onBytes
    }

    func begin(_ continuation: CheckedContinuation<Void, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    private func fail(_ failure: MeetingModelTransportError) {
        state.withLock { state in
            if state.failure == nil { state.failure = failure }
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(.transferFailed)
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            fail(.httpStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > maximumBytes {
            fail(.tooLarge)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isOver = state.withLock { state -> Bool in
            guard state.failure == nil else { return true }
            state.received += Int64(data.count)
            if state.received > maximumBytes {
                state.failure = .tooLarge
                return true
            }
            return false
        }
        if isOver {
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(.diskWrite)
            dataTask.cancel()
            return
        }
        onBytes(Int64(data.count))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        let (continuation, failure) = state.withLock {
            state -> (CheckedContinuation<Void, any Error>?, MeetingModelTransportError?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, state.failure)
        }
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            let isCancelled = (error as? URLError)?.code == .cancelled
            continuation.resume(
                throwing: isCancelled
                    ? CancellationError() : MeetingModelTransportError.transferFailed)
        } else {
            continuation.resume()
        }
    }
}
