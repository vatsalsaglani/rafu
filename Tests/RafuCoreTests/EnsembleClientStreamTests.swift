import Darwin
import Foundation
import Synchronization
import Testing

@testable import RafuCore

@Suite("Ensemble streaming client", .serialized)
struct EnsembleClientStreamTests {
    @Test("One-shot status preserves handshake then request connections")
    func oneShotStatus() async throws {
        let handshakePair = try ensembleSocketPair()
        let statusPair = try ensembleSocketPair()
        let descriptors = EnsembleDescriptorQueue([
            handshakePair.client, statusPair.client,
        ])
        let handshakeServer = serveEnsembleOneShot(
            handshakePair.server,
            response: .accepted(
                workspaceMatched: false,
                windowFocused: false,
                waitSupported: false
            )
        )
        let status = EnsembleStatusResult(
            runs: [],
            cursor: 9,
            verbVersion: LauncherIPCProtocol.ensembleVerbVersion,
            tree: false
        )
        let statusServer = serveEnsembleOneShot(
            statusPair.server,
            response: .ensemble(.status(status))
        )

        let response = try EnsembleCLIClient(connector: { try descriptors.take() })
            .performEnsemble(
                EnsembleRequestPayload(verb: "status", workingDirectory: "/work"))
        let handshake = try await handshakeServer.value
        let request = try await statusServer.value

        #expect(handshake.kind == .handshake)
        #expect(request.kind == .ensembleStatus)
        #expect(request.ensemble?.verb == "status")
        #expect(response == .status(status))
        #expect(descriptors.isEmpty)
    }

    @Test("Await subscribes before its snapshot and consumes a queued state event")
    func subscribeThenSnapshotNoLostWakeup() async throws {
        let harness = try AwaitHarness(
            heartbeatTimeout: 0.5,
            snapshotState: .running,
            events: [
                stateEvent(cursor: 2, state: .completed)
            ]
        )
        let result = harness.runner.run(
            .await(
                runIDs: ["run-a"],
                states: [.completed],
                any: false,
                timeout: 1,
                json: false
            ),
            workingDirectory: "/work"
        )
        try await harness.finish()

        #expect(
            result.exitCode == .ok,
            Comment(rawValue: result.standardError)
        )
        #expect(result.standardOutput == "run-a completed")
        #expect(harness.order.values == ["subscribe", "handshake", "status"])
    }

    @Test("Heartbeat frames keep a subscription live until its state event")
    func heartbeatKeepsStreamAlive() async throws {
        let harness = try AwaitHarness(
            heartbeatTimeout: 0.1,
            snapshotState: .running,
            events: [
                heartbeatEvent(cursor: 2),
                heartbeatEvent(cursor: 3),
                stateEvent(cursor: 4, state: .completed),
            ]
        )
        let result = harness.runner.run(
            .await(
                runIDs: ["run-a"],
                states: [.completed],
                any: false,
                timeout: 1,
                json: true
            ),
            workingDirectory: "/work"
        )
        try await harness.finish()

        #expect(
            result.exitCode == .ok,
            Comment(rawValue: result.standardError)
        )
        #expect(result.standardOutput.contains("\"cursor\" : 4"))
        #expect(result.standardOutput.contains("\"completed\""))
    }

    @Test("Three missed heartbeat intervals map to unavailable")
    func missedHeartbeatsAreUnavailable() async throws {
        let harness = try AwaitHarness(
            heartbeatTimeout: 0.05,
            snapshotState: .running,
            events: [],
            holdSubscriptionOpen: true
        )
        let result = harness.runner.run(
            .await(
                runIDs: ["run-a"],
                states: [.completed],
                any: false,
                timeout: nil,
                json: false
            ),
            workingDirectory: "/work"
        )
        try await harness.finish()

        #expect(result.exitCode == .unavailable)
        #expect(result.standardError.contains("missed three Ensemble heartbeats"))
    }

    @Test("Partial event bytes do not reset the complete-frame heartbeat deadline")
    func partialFrameDoesNotExtendHeartbeatDeadline() async throws {
        let pair = try ensembleSocketPair()
        let server = servePartialEnsembleEvent(pair.server)
        let client = EnsembleCLIClient(
            heartbeatTimeout: 0.1,
            connector: { pair.client }
        )

        do {
            try client.subscribe(
                payload: EnsembleRequestPayload(
                    verb: "await",
                    workingDirectory: "/work",
                    runIDs: ["run-a"],
                    states: [.completed]
                ),
                timeout: nil,
                onSubscribed: { _ in false },
                onEvent: { _ in false }
            )
            Issue.record("Expected the incomplete event frame to miss its heartbeat deadline")
        } catch let error as EnsembleCLIClientError {
            #expect(error == .heartbeatTimeout)
        }

        let request = try await server.value
        #expect(request.kind == .ensembleSubscribe)
    }

    @Test("Client-side --timeout maps to temporary failure")
    func clientTimeoutIsTemporaryFailure() async throws {
        let harness = try AwaitHarness(
            heartbeatTimeout: 1,
            snapshotState: .running,
            events: [],
            holdSubscriptionOpen: true
        )
        let result = harness.runner.run(
            .await(
                runIDs: ["run-a"],
                states: [.completed],
                any: false,
                timeout: 0.05,
                json: false
            ),
            workingDirectory: "/work"
        )
        try await harness.finish()

        #expect(result.exitCode == .tempFail)
        #expect(result.standardError.contains("timed out"))
    }

    @Test("The initial snapshot can satisfy --any immediately")
    func snapshotSatisfiesAny() async throws {
        let harness = try AwaitHarness(
            heartbeatTimeout: 0.5,
            snapshotState: .failed,
            events: [],
            holdSubscriptionOpen: true
        )
        let result = harness.runner.run(
            .await(
                runIDs: ["run-a", "run-b"],
                states: [.failed],
                any: true,
                timeout: 1,
                json: false
            ),
            workingDirectory: "/work"
        )
        try await harness.finish()

        #expect(result.exitCode == .ok)
        #expect(result.standardOutput == "run-a failed")
    }
}

private final class AwaitHarness: Sendable {
    let runner: EnsembleCommandRunner
    let order: EnsembleOrderRecorder

    private let subscriptionTask: Task<LauncherIPCEnvelope, Error>
    private let handshakeTask: Task<LauncherIPCEnvelope, Error>
    private let statusTask: Task<LauncherIPCEnvelope, Error>

    init(
        heartbeatTimeout: TimeInterval,
        snapshotState: EnsembleRunState,
        events: [EnsembleEvent],
        holdSubscriptionOpen: Bool = false
    ) throws {
        let subscriptionPair = try ensembleSocketPair()
        let handshakePair = try ensembleSocketPair()
        let statusPair = try ensembleSocketPair()
        let descriptors = EnsembleDescriptorQueue([
            subscriptionPair.client,
            handshakePair.client,
            statusPair.client,
        ])
        let order = EnsembleOrderRecorder()
        self.order = order

        subscriptionTask = serveEnsembleSubscription(
            subscriptionPair.server,
            events: events,
            holdOpenUntilPeerCloses: holdSubscriptionOpen,
            onEnvelope: { _ in order.append("subscribe") }
        )
        handshakeTask = serveEnsembleOneShot(
            handshakePair.server,
            response: .accepted(
                workspaceMatched: false,
                windowFocused: false,
                waitSupported: false
            ),
            onEnvelope: { _ in order.append("handshake") }
        )
        let snapshot = EnsembleStatusResult(
            runs: [
                EnsembleRunSummary(
                    runID: "run-a",
                    workflowName: "Implement",
                    state: snapshotState,
                    steps: [],
                    usageLines: []
                )
            ],
            cursor: 1,
            verbVersion: LauncherIPCProtocol.ensembleVerbVersion,
            tree: false
        )
        statusTask = serveEnsembleOneShot(
            statusPair.server,
            response: .ensemble(.status(snapshot)),
            onEnvelope: { _ in order.append("status") }
        )
        runner = EnsembleCommandRunner(
            client: EnsembleCLIClient(
                heartbeatTimeout: heartbeatTimeout,
                connector: { try descriptors.take() }
            ))
    }

    func finish() async throws {
        let subscription = try await subscriptionTask.value
        let handshake = try await handshakeTask.value
        let status = try await statusTask.value
        #expect(subscription.kind == .ensembleSubscribe)
        #expect(handshake.kind == .handshake)
        #expect(status.kind == .ensembleStatus)
    }
}

private struct EnsembleSocketPair {
    let client: Int32
    let server: Int32
}

private let ensembleSIGPIPEIgnored: Void = {
    signal(SIGPIPE, SIG_IGN)
}()

private func ensembleSocketPair() throws -> EnsembleSocketPair {
    _ = ensembleSIGPIPEIgnored
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw EnsembleCLIClientError.systemCall(name: "socketpair", code: errno)
    }
    for descriptor in descriptors {
        var one: Int32 = 1
        _ = Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &one,
            socklen_t(MemoryLayout.size(ofValue: one))
        )
    }
    return EnsembleSocketPair(client: descriptors[0], server: descriptors[1])
}

private final class EnsembleDescriptorQueue: Sendable {
    private let storage: Mutex<[Int32]>

    init(_ descriptors: [Int32]) {
        storage = Mutex(descriptors)
    }

    var isEmpty: Bool {
        storage.withLock { $0.isEmpty }
    }

    func take() throws -> Int32 {
        try storage.withLock { descriptors in
            guard !descriptors.isEmpty else {
                throw EnsembleCLIClientError.disconnected
            }
            return descriptors.removeFirst()
        }
    }
}

private final class EnsembleOrderRecorder: Sendable {
    private let storage = Mutex<[String]>([])

    var values: [String] {
        storage.withLock { $0 }
    }

    func append(_ value: String) {
        storage.withLock { $0.append(value) }
    }
}

private func serveEnsembleOneShot(
    _ fileDescriptor: Int32,
    response: LauncherIPCResponse,
    onEnvelope: @escaping @Sendable (LauncherIPCEnvelope) -> Void = { _ in }
) -> Task<LauncherIPCEnvelope, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
        of: LauncherIPCEnvelope.self)
    Thread.detachNewThread {
        defer { Darwin.close(fileDescriptor) }
        do {
            let envelope = try readEnsembleEnvelope(from: fileDescriptor)
            onEnvelope(envelope)
            try writeEnsembleFrame(LauncherIPCCodec.encode(response), to: fileDescriptor)
            continuation.yield(envelope)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    return Task {
        for try await envelope in stream {
            return envelope
        }
        throw EnsembleCLIClientError.disconnected
    }
}

private func serveEnsembleSubscription(
    _ fileDescriptor: Int32,
    events: [EnsembleEvent],
    holdOpenUntilPeerCloses: Bool,
    onEnvelope: @escaping @Sendable (LauncherIPCEnvelope) -> Void
) -> Task<LauncherIPCEnvelope, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
        of: LauncherIPCEnvelope.self)
    Thread.detachNewThread {
        defer { Darwin.close(fileDescriptor) }
        do {
            let envelope = try readEnsembleEnvelope(from: fileDescriptor)
            onEnvelope(envelope)
            try writeEnsembleFrame(
                LauncherIPCCodec.encode(
                    LauncherIPCResponse.ensemble(.subscribed(cursor: 1))),
                to: fileDescriptor
            )
            for event in events {
                try writeEnsembleFrame(LauncherIPCCodec.encode(event), to: fileDescriptor)
            }
            if holdOpenUntilPeerCloses {
                var byte: UInt8 = 0
                while Darwin.read(fileDescriptor, &byte, 1) > 0 {}
            }
            continuation.yield(envelope)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    return Task {
        for try await envelope in stream {
            return envelope
        }
        throw EnsembleCLIClientError.disconnected
    }
}

private func servePartialEnsembleEvent(
    _ fileDescriptor: Int32
) -> Task<LauncherIPCEnvelope, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
        of: LauncherIPCEnvelope.self)
    Thread.detachNewThread {
        defer { Darwin.close(fileDescriptor) }
        do {
            let envelope = try readEnsembleEnvelope(from: fileDescriptor)
            try writeEnsembleFrame(
                LauncherIPCCodec.encode(
                    LauncherIPCResponse.ensemble(.subscribed(cursor: 1))),
                to: fileDescriptor
            )
            let frame = try LauncherIPCCodec.encode(
                stateEvent(cursor: 2, state: .completed))
            for rawByte in frame.prefix(8) {
                var byte = rawByte
                let count = Darwin.write(fileDescriptor, &byte, 1)
                if count != 1 { break }
                usleep(20_000)
            }
            continuation.yield(envelope)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    return Task {
        for try await envelope in stream {
            return envelope
        }
        throw EnsembleCLIClientError.disconnected
    }
}

private func readEnsembleEnvelope(from fileDescriptor: Int32) throws -> LauncherIPCEnvelope {
    var decoder = LauncherIPCFrameDecoder()
    var storage = [UInt8](repeating: 0, count: 512)
    while true {
        let count = storage.withUnsafeMutableBytes { bytes in
            Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw EnsembleCLIClientError.systemCall(name: "read", code: errno)
        }
        guard count > 0 else { throw EnsembleCLIClientError.disconnected }
        if let body = try decoder.consume(Data(storage.prefix(count))).first {
            return try LauncherIPCCodec.decode(LauncherIPCEnvelope.self, from: body)
        }
    }
}

private func writeEnsembleFrame(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                fileDescriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw EnsembleCLIClientError.systemCall(name: "write", code: errno)
            }
            guard count > 0 else { throw EnsembleCLIClientError.disconnected }
            offset += count
        }
    }
}

private func heartbeatEvent(cursor: UInt64) -> EnsembleEvent {
    EnsembleEvent(
        cursor: cursor,
        at: Date(timeIntervalSince1970: TimeInterval(cursor)),
        runID: "",
        kind: "heartbeat"
    )
}

private func stateEvent(cursor: UInt64, state: EnsembleRunState) -> EnsembleEvent {
    EnsembleEvent(
        cursor: cursor,
        at: Date(timeIntervalSince1970: TimeInterval(cursor)),
        runID: "run-a",
        kind: "state",
        state: state
    )
}
