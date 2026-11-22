import Foundation
import RafuCore
import Synchronization

@testable import RafuApp

/// One step of a scripted helper.
nonisolated enum FakeWorkerStep: Sendable {
    case lines([MeetingWorkerEvent])
    case raw(Data)
    /// Waits until the client closes standard input.
    case waitForInputClose
    case exit(Int32)
    case signal(Int32)
    /// Never ends by itself (until `terminate()`).
    case hang
}

/// A helper with no process: it records what the client writes and plays
/// a recorded line sequence, or lets the test emit lines by hand.
nonisolated final class FakeWorkerConnection: MeetingWorkerConnection {
    private struct State {
        var writes: [(data: Data, droppable: Bool)] = []
        var inputClosed = false
        var terminated = false
        var termination: MeetingWorkerTermination?
        var waiters: [CheckedContinuation<MeetingWorkerTermination, Never>] = []
        var closeWaiters: [CheckedContinuation<Void, Never>] = []
        var requestWaiters: [CheckedContinuation<Void, Never>] = []
        var started = false
    }

    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state = Mutex(State())
    private let script: [FakeWorkerStep]?

    /// `script` nil = the test emits lines by hand.
    init(script: [FakeWorkerStep]?) {
        (output, continuation) = AsyncStream<Data>.makeStream()
        self.script = script
    }

    var droppedFrameCount: Int { 0 }

    var writes: [Data] { state.withLock { $0.writes.map(\.data) } }
    var isInputClosed: Bool { state.withLock { $0.inputClosed } }
    var wasTerminated: Bool { state.withLock { $0.terminated } }

    /// The request line (the first write), decoded.
    var request: MeetingWorkerRequest? {
        guard let first = writes.first else { return nil }
        return try? MeetingWorkerRequest.decode(line: first.dropLast())
    }

    /// The live frames written after the request.
    var frames: [MeetingWorkerFrame] {
        var parser = MeetingWorkerFrameParser()
        return writes.dropFirst().flatMap { (try? parser.append($0)) ?? [] }
    }

    func send(_ data: Data, droppable: Bool) {
        let (start, waiters) = state.withLock {
            state -> (Bool, [CheckedContinuation<Void, Never>]) in
            state.writes.append((data, droppable))
            let first = !state.started
            state.started = true
            let waiting = state.requestWaiters
            state.requestWaiters = []
            return (first, waiting)
        }
        for waiter in waiters { waiter.resume() }
        if start, let script {
            Task { await self.play(script) }
        }
    }

    /// Waits until the client has sent its request line.
    func waitForRequest() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if !state.writes.isEmpty { return true }
                state.requestWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func closeInput() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.inputClosed = true
            let waiting = state.closeWaiters
            state.closeWaiters = []
            return waiting
        }
        for waiter in waiters { waiter.resume() }
    }

    func terminate() {
        let already = state.withLock { state -> Bool in
            let ended = state.termination != nil
            state.terminated = true
            return ended
        }
        if !already { end(.signalled(15)) }
    }

    func termination() async -> MeetingWorkerTermination {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> MeetingWorkerTermination? in
                if let termination = state.termination { return termination }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    // MARK: Test controls

    func emit(_ events: [MeetingWorkerEvent]) {
        for event in events {
            for part in event.batched() {
                if let line = try? part.encodedLine() { continuation.yield(line) }
            }
        }
    }

    func emitRaw(_ data: Data) {
        continuation.yield(data)
    }

    func end(_ termination: MeetingWorkerTermination) {
        let waiters = state.withLock {
            state -> [CheckedContinuation<MeetingWorkerTermination, Never>]? in
            guard state.termination == nil else { return nil }
            state.termination = termination
            let waiting = state.waiters
            state.waiters = []
            return waiting
        }
        guard let waiters else { return }
        continuation.finish()
        for waiter in waiters { waiter.resume(returning: termination) }
    }

    func waitForInputClose() async {
        await withCheckedContinuation { continuation in
            let closed = state.withLock { state -> Bool in
                if state.inputClosed { return true }
                state.closeWaiters.append(continuation)
                return false
            }
            if closed { continuation.resume() }
        }
    }

    private func play(_ script: [FakeWorkerStep]) async {
        for step in script {
            if state.withLock({ $0.termination != nil }) { return }
            switch step {
            case .lines(let events): emit(events)
            case .raw(let data): emitRaw(data)
            case .waitForInputClose: await waitForInputClose()
            case .exit(let code):
                end(.exited(code))
                return
            case .signal(let number):
                end(.signalled(number))
                return
            case .hang:
                return
            }
            await Task.yield()
        }
    }
}

nonisolated enum FakeLaunchError: Error {
    case refused
}

/// Gives one connection for each launch, from a queue of scripts.
nonisolated final class FakeWorkerLauncher: MeetingWorkerLaunching {
    private struct State {
        var scripts: [[FakeWorkerStep]?] = []
        var failLaunches = 0
        var specs: [MeetingWorkerLaunchSpec] = []
        var connections: [FakeWorkerConnection] = []
        var running = 0
        var maximumRunning = 0
        var launchWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())
    /// A script for launches past the queue (nil = manual).
    private let defaultScript: [FakeWorkerStep]?

    init(scripts: [[FakeWorkerStep]?] = [], defaultScript: [FakeWorkerStep]? = nil) {
        state.withLock { $0.scripts = scripts }
        self.defaultScript = defaultScript
    }

    /// The next `count` launches throw.
    func failNextLaunches(_ count: Int) {
        state.withLock { $0.failLaunches = count }
    }

    var specs: [MeetingWorkerLaunchSpec] { state.withLock { $0.specs } }
    var connections: [FakeWorkerConnection] { state.withLock { $0.connections } }
    var maximumRunning: Int { state.withLock { $0.maximumRunning } }

    func launch(_ spec: MeetingWorkerLaunchSpec) throws -> any MeetingWorkerConnection {
        let result = state.withLock {
            state -> (FakeWorkerConnection?, [CheckedContinuation<Void, Never>]) in
            state.specs.append(spec)
            if state.failLaunches > 0 {
                state.failLaunches -= 1
                return (nil, Self.readyWaiters(&state))
            }
            let script = state.scripts.isEmpty ? defaultScript : state.scripts.removeFirst()
            let connection = FakeWorkerConnection(script: script)
            state.connections.append(connection)
            state.running += 1
            state.maximumRunning = max(state.maximumRunning, state.running)
            return (connection, Self.readyWaiters(&state))
        }
        for waiter in result.1 { waiter.resume() }
        guard let connection = result.0 else { throw FakeLaunchError.refused }
        Task {
            _ = await connection.termination()
            self.state.withLock { $0.running -= 1 }
        }
        return connection
    }

    private static func readyWaiters(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        let count = state.specs.count
        let ready = state.launchWaiters.filter { $0.count <= count }.map(\.continuation)
        state.launchWaiters.removeAll { $0.count <= count }
        return ready
    }

    /// Waits until `count` launches (good or failed) have happened.
    func waitForLaunches(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.specs.count >= count { return true }
                state.launchWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// The connection of launch `index` (0-based, counting good launches).
    func connection(_ index: Int) async -> FakeWorkerConnection {
        while true {
            let found = state.withLock {
                $0.connections.count > index ? $0.connections[index] : nil
            }
            if let found { return found }
            await waitForLaunches(state.withLock { $0.specs.count } + 1)
        }
    }
}

/// A locator with fixed folders.
nonisolated struct FakeModelLocator: MeetingModelLocating {
    var folders: [MeetingModelID: URL]

    func installedFolder(for model: MeetingModelID) async -> URL? { folders[model] }
}

/// Records diagnostics events.
nonisolated final class RecordingDiagnostics: MeetingDiagnosticsRecording {
    private let events = Mutex<[MeetingDiagnosticEvent]>([])

    func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {
        events.withLock { $0.append(event) }
    }

    var recorded: [MeetingDiagnosticEvent] { events.withLock { $0 } }
}
