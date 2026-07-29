import Foundation

/// Tees one Conductor run's rendered PTY output to
/// `.rafu/runs/<id>/logs/output.log` — evidence only, never Rafu's own
/// logging (AGENTS.md: process/document content is never logged). Bounded to
/// `byteCap` so a runaway or hostile child cannot grow the run directory
/// without limit.
///
/// `record(_:)` is called from `RafuTerminalView.dataReceived(slice:)`'s
/// main-actor block on every pty read, so its accounting (a byte counter and
/// a `didTruncate` flag) must stay `O(1)` and synchronous — the frame-budget
/// invariant (AGENTS.md) forbids blocking that call on file I/O. The only
/// value crossing off the main actor is the copied `Data` chunk itself
/// (`Sendable`), handed to a SINGLE consumer through an `AsyncStream`; a
/// single producer's yields arrive at a single `for await` consumer strictly
/// in order, so this stays correct without any lock or `@unchecked
/// Sendable`.
///
/// The `FileHandle` is opened, written, and closed entirely inside
/// `drain(_:into:)`, a `nonisolated` function that runs off the main actor
/// for its whole lifetime — it is never constructed on, handed to, or closed
/// from the main actor, and never shared across two tasks.
@MainActor
final class ConductorRunOutputCapture {
    /// 8 MiB: generous for a full role session transcript, bounded so a
    /// runaway or hostile child cannot grow `.rafu/runs/` without limit.
    static let byteCap = 8 * 1_024 * 1_024

    /// Written exactly once, as the stream's final chunk, the moment the cap
    /// is crossed.
    private static let truncationMarker = "\n[rafu: run output truncated at 8 MiB]\n"

    private let continuation: AsyncStream<Data>.Continuation
    private let consumerTask: Task<Void, Never>
    private let renderer: any ConductorRunOutputRendering
    private var bytesWritten = 0
    private var didTruncate = false

    init(
        outputLogURL: URL,
        renderer: (any ConductorRunOutputRendering)? = nil
    ) {
        self.renderer = renderer ?? ConductorRunTerminalOutputRenderer()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        consumerTask = Task {
            await Self.drain(stream, into: outputLogURL)
        }
    }

    /// Renders the raw PTY bytes before both the terminal and `output.log`
    /// receive them. This is display/evidence work only: an error falls back
    /// to the original bytes and is never reported to a run controller.
    func render(_ slice: ArraySlice<UInt8>) -> Data {
        do {
            return try renderer.render(slice)
        } catch {
            return Data(slice)
        }
    }

    /// Emits a final unterminated line when the child exits. The production
    /// renderer never throws; an injected renderer failure has no run-state
    /// path and therefore safely emits no synthetic completion signal.
    func finishRendering() -> Data {
        do {
            return try renderer.finish()
        } catch {
            return Data()
        }
    }

    /// Main-actor accounting for one pty read. Copies only the slice's
    /// allowed prefix (never more than `byteCap` total across the run's
    /// lifetime) into a fresh `Data` and yields it to the consumer; once the
    /// cap is crossed, appends the truncation marker exactly once and
    /// finishes the stream. A no-op once truncated.
    func record(_ slice: ArraySlice<UInt8>) {
        guard !didTruncate else { return }
        let remaining = max(0, Self.byteCap - bytesWritten)
        let allowed = slice.prefix(remaining)
        if !allowed.isEmpty {
            continuation.yield(Data(allowed))
            bytesWritten += allowed.count
        }
        if bytesWritten >= Self.byteCap {
            didTruncate = true
            continuation.yield(Data(Self.truncationMarker.utf8))
            continuation.finish()
        }
    }

    /// Explicit end of capture — called on both natural process exit and
    /// explicit terminal shutdown. Safe to call after `record(_:)` already
    /// truncated and finished the stream: `AsyncStream.Continuation.finish()`
    /// is idempotent.
    func finish() {
        continuation.finish()
    }

    /// Awaits the consumer's completion — deterministic test synchronization
    /// with no sleeps or polling.
    func waitUntilFinished() async {
        await consumerTask.value
    }

    /// The one place this run's evidence file is opened, written, and
    /// closed. `nonisolated` in this PRIMARY declaration (never a bare
    /// extension — see `ConductorCore.swift`'s note on why that distinction
    /// matters under `RafuApp`'s `.defaultIsolation(MainActor.self)`) so
    /// calling it from `init`'s `Task` genuinely runs off the main actor:
    /// the surrounding `Task` starts main-actor-isolated, but hops off for
    /// the duration of this `await`, which is where every blocking
    /// `write(contentsOf:)` call actually happens.
    private nonisolated static func drain(_ stream: AsyncStream<Data>, into url: URL) async {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        for await chunk in stream {
            try? handle.write(contentsOf: chunk)
        }
        try? handle.close()
    }
}
