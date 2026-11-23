import Foundation
import RafuCore

/// How a driven process ended.
nonisolated enum MeetingAgentDriveEnd: Equatable, Sendable {
    /// Standard output ended and the process exited.
    case finished
    /// The parser asked to end the process.
    case stopped
    case outputTooLarge
    case timedOut
    case cancelled
}

/// What the reader reports while a process runs.
nonisolated enum MeetingAgentDriveEvent: Sendable {
    /// The process started.
    case started
    /// Streamed answer text from the parser.
    case text([MeetingAgentTextEvent])
}

/// The process did not start.
nonisolated struct MeetingAgentLaunchFailed: Error {}

/// Starts one hidden agent process and reads its output with a parser
/// until the end, a stop, the byte limit, the time limit or cancellation.
/// The process is always ended before `run` returns. Shared by the runner
/// and the probe.
nonisolated enum MeetingAgentDrive {
    struct Result<P: MeetingAgentStreamParsing>: Sendable {
        var parser: P
        var end: MeetingAgentDriveEnd
        var termination: MeetingAgentTermination?
    }

    private enum Step<P: MeetingAgentStreamParsing>: Sendable {
        case read(P, MeetingAgentDriveEnd)
        case timedOut
        case timerEnded
    }

    static func run<P: MeetingAgentStreamParsing>(
        _ spec: MeetingAgentProcessSpec, parser: P, processRunner: any MeetingAgentProcessRunning,
        timeLimit: Duration, maximumOutputBytes: Int = MeetingAgentLimits.maximumOutputBytes,
        onEvent: (@Sendable (MeetingAgentDriveEvent) -> Void)? = nil
    ) async throws -> Result<P> {
        if Task.isCancelled { throw CancellationError() }
        let handle: any MeetingAgentProcessHandle
        do {
            handle = try processRunner.start(spec)
        } catch {
            throw MeetingAgentLaunchFailed()
        }
        onEvent?(.started)
        let (finalParser, end) = await withTaskCancellationHandler {
            await withTaskGroup(of: Step<P>.self) { group -> (P, MeetingAgentDriveEnd) in
                group.addTask {
                    await read(
                        handle, parser: parser, maximumOutputBytes: maximumOutputBytes,
                        onEvent: onEvent)
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeLimit)
                        return .timedOut
                    } catch {
                        return .timerEnded
                    }
                }
                var timedOut = false
                var didRead = false
                var result: (P, MeetingAgentDriveEnd) = (parser, .cancelled)
                while let step = await group.next() {
                    switch step {
                    case .read(let finished, let end):
                        didRead = true
                        result = (finished, end)
                        group.cancelAll()
                    case .timedOut:
                        // A reader that already ended wins over a late timer.
                        guard !didRead else { break }
                        timedOut = true
                        handle.terminate()
                        group.cancelAll()
                    case .timerEnded:
                        break
                    }
                }
                if timedOut { return (result.0, .timedOut) }
                if Task.isCancelled { return (result.0, .cancelled) }
                return result
            }
        } onCancel: {
            handle.terminate()
        }
        handle.terminate()
        let termination = await handle.termination()
        return Result(parser: finalParser, end: end, termination: termination)
    }

    private static func read<P: MeetingAgentStreamParsing>(
        _ handle: any MeetingAgentProcessHandle, parser: P, maximumOutputBytes: Int,
        onEvent: (@Sendable (MeetingAgentDriveEvent) -> Void)?
    ) async -> Step<P> {
        var parser = parser
        var splitter = MeetingAgentLineSplitter(maximumOutputBytes: maximumOutputBytes)
        func consume(_ line: Data) -> Bool {
            let verdict = parser.consume(line: line)
            let events = parser.takeTextEvents()
            if !events.isEmpty, verdict == .more { onEvent?(.text(events)) }
            return verdict == .stop
        }
        for await chunk in handle.output {
            let lines: [Data]
            do {
                lines = try splitter.append(chunk)
            } catch {
                handle.terminate()
                return .read(parser, .outputTooLarge)
            }
            for line in lines where consume(line) {
                handle.terminate()
                return .read(parser, .stopped)
            }
        }
        if Task.isCancelled { return .read(parser, .cancelled) }
        if let last = splitter.finish(), consume(last) {
            handle.terminate()
            return .read(parser, .stopped)
        }
        // The exit is inside the time limit too.
        _ = await handle.termination()
        return .read(parser, .finished)
    }
}
