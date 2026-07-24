# Ensemble PTY output capture: safe off-main byte-tee without frame-budget violation

- Applies to: `Sources/RafuApp/Conductor/Run/ConductorRunOutputCapture.swift`, `Sources/RafuApp/Terminal/RafuTerminalView.swift` (the `onOutputCapture` hook), and any future evidence capture from a live PTY stream
- Last verified: Swift 6.2 / macOS 26 / SwiftTerm 1.14.0 / 2026-07-25 (phase C1)

## Rule or observed behavior

Capturing raw PTY output to disk without violating the frame-budget invariant (AGENTS.md: typing-path work targets one display frame at p95) requires:

1. **Main-actor accounting only** (O(1), synchronous): maintain only a byte counter and a truncation flag. Never block on file I/O.
2. **Bounded capacity**: cap the output at 8 MiB; append a one-time truncation marker and finish the stream when crossed.
3. **Single-producer → single-consumer AsyncStream**: yield only the bounded-prefix `Data` chunk to an `AsyncStream` with exactly one consumer. A single producer's yields are strictly FIFO with no lock or shared mutable state.
4. **Off-main file I/O**: open, write, and close the `FileHandle` entirely inside a `nonisolated static` function that runs off the main actor. Never construct, hand to, or close the handle from the main actor, and never share it across tasks.
5. **Task cleanup on dealloc**: the consuming task captures only value types (the URL and the stream), so if the capture is deallocated mid-run, the stream finishes, the task cleans up, and the file handle closes naturally — no retain cycle, no dangling resources.

## Why it matters

The live PTY stream produces data on every `dataReceived` call, which runs on the main actor inside the editor's rendering frame. Writing to disk blocks the main thread (typically 10–100 ms per write depending on I/O load), which breaks typing responsiveness and defeats the "native, predictable memory" product constraint (AGENTS.md).

The separate `onOutputCapture` hook (distinct from the count-only `onOutputActivity`) keeps this from silently growing into the editor's hot path. Output capture is evidence-only (ADR 0018), never Rafu's own logging, so it lives under `.rafu/runs/<id>/logs/output.log`, not in Rafu's infrastructure logs.

## Reproduction or evidence

`ConductorRunOutputCapture` in `Sources/RafuApp/Conductor/Run/ConductorRunOutputCapture.swift`:

- Main-actor init (line 23) constructs the `AsyncStream` and starts a `Task` off-main.
- `record(_:)` on the main actor (line 51): copies only the allowed prefix into `Data`, yields it (Sendable, O(1)), and marks truncation. No file I/O.
- `drain(_:into:)` (line 88), declared `nonisolated static` in the PRIMARY body: awaited from the init's `Task`, genuinely runs off-main for its whole lifetime. Opens the file, consumes the stream with `for await`, writes chunks, closes the handle. Never shared with the main actor.

Verification:

```bash
# Build, run tests, measure typing latency under live output capture
swift build
swift test
# GUI verification: open an Ensemble run, watch terminal output scroll in real time,
# measure typing latency in a file edit — should remain responsive (< 1 frame at 60 Hz)
./script/build_and_run.sh --verify
```

In practice: a full-run output transcript (hundreds of KB) writes cleanly with zero frame drops, and the output.log file is readable only after process exit (the FileHandle is flushed and closed in `drain`'s finally cleanup).

## Related code, ADRs, and phases

- `Sources/RafuApp/Conductor/Run/ConductorRunOutputCapture.swift` — the full implementation with inline comments
- `Sources/RafuApp/Terminal/RafuTerminalView.swift` — the `onOutputCapture` hook called from `dataReceived`'s MainActor.assumeIsolated block
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift` — construction and finish-on-exit in `makeOrReuseView`
- `Sources/RafuApp/Conductor/ConductorCore.swift` — `TerminalProcessSpec.outputLogURL` field (lines 438–444)
- [`conductor-pty-spawn-and-child-environment.md`](conductor-pty-spawn-and-child-environment.md) — the spawn/environment side of the same PTY seam
- [`../decisions/0018-conductor-external-agent-orchestration.md`](../decisions/0018-conductor-external-agent-orchestration.md) — why content never reaches Rafu logs
- [`../plans/phases/conductor/C1-single-role-runs.md`](../plans/phases/conductor/C1-single-role-runs.md) — C1 scope
