# Concurrency boundaries

- **Applies to:** Observation state, filesystem work, process I/O, syntax, SSH, Git, AI, and tests
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-12

## Module defaults

`RafuApp` uses Swift 6.2 default `MainActor` isolation because it is a UI/lifecycle module. `RafuCore` and `RafuCLI` remain nonisolated by default so shared value types and command parsing do not acquire accidental UI isolation.

This is a per-target setting. Never infer another target's isolation from app behavior.

## Boundary rules

- UI-visible coordination and `WorkspaceSession` are main-actor isolated.
- Prefer immutable `Sendable` structs/enums across boundaries.
- Use actors only for state that needs an independent serialization domain; do not create forwarding actors with no meaningful state.
- After every `await` inside an actor, revalidate assumptions about mutable actor state.
- Prefer structured concurrency and direct async APIs. Avoid `Task.detached`, fire-and-forget tasks, and broad GCD queues.
- CPU-heavy parsing may need an explicitly concurrent boundary; ordinary async I/O suspends and does not justify manual thread hopping.
- Long-running operations need cancellation ownership and stale-result rejection based on identity/revision.
- Subprocess wrappers must drain stdout and stderr concurrently without blocking an actor or the main thread.
- Never introduce `@unchecked Sendable` merely to silence strict-concurrency diagnostics.

## GCD DispatchSource handler isolation under default-MainActor

- Applies to: `Sources/RafuApp/Services/MemoryPressureMonitor.swift` and any closure passed to `DispatchSource.setEventHandler`, `dispatch_source_set_event_handler`, or similar C-callback APIs
- Last verified: Swift 6.2.4, macOS 26.1 on 2026-07-16

Under a target's default `MainActor` isolation (such as `RafuApp`), a bare closure passed to `DispatchSource.setEventHandler(_:)` is inferred to be `@MainActor`-isolated by the type checker. However, DispatchSource invokes the handler on its target queue (a private serial queue), NOT the main actor. At runtime, Swift 6's strict executor check (`swift_task_isCurrentExecutor`) trips `dispatch_assert_queue` and kills the process with `EXC_BREAKPOINT (SIGTRAP)`.

The compiler does not flag this because the Dispatch handler parameter is not strongly typed to reject a MainActor closure — the mismatch is only detected at runtime when the event fires. CI and unit tests typically miss it because they trigger handlers via testable seams (direct `broadcast()` calls) or do not wait long enough for real system events (memory pressure) to fire.

**Fix:** Mark the handler closure explicitly `@Sendable` (which makes it non-isolated) and hop to the main actor internally:

```swift
newSource.setEventHandler { @Sendable [weak newSource] in
  // Handler runs on the private queue; do non-blocking work here
  Task { @MainActor in
    // Transition to main actor to touch @MainActor state
    self.broadcast(...)
  }
}
```

**Contrast:** A `NotificationCenter.addObserver(forName:object:queue:using:)` block with `queue: .main` DOES run on the main thread, so `MainActor.assumeIsolated { }` there is safe and correct. The navigation-features implementation relies on exactly this (clip-view scroll observer on `.main` queue).

**Why it matters:** This is a platform-specific isolation trap that evades compile-time detection and reproduces only under real system conditions. Existing codebase grep for `DispatchSource.setEventHandler` is the verification method; MemoryPressureMonitor was the only instance.

## FSEvents bridging under strict concurrency

- Applies to: `Sources/RafuApp/Services/WorkspaceLivenessService.swift`
- Last verified: Swift 6.2.4, macOS 26.1 on 2026-07-13

The FSEvents C callback cannot capture state and is not actor-isolated. The verified pattern: a `nonisolated final class` relay whose only stored property is an `AsyncStream<[String]>.Continuation` (honest `Sendable`, no `@unchecked`), passed through `FSEventStreamContext.info` via `Unmanaged.passUnretained` while the owning `@MainActor` service retains it until after `FSEventStreamInvalidate`. Deliver events with `FSEventStreamSetDispatchQueue` on a private serial queue; the `@MainActor` service consumes the stream with an inherited-isolation `Task`, so classification and UI refresh stay on the main actor without locks. In a default-`MainActor` target the callback must be a file-private `nonisolated func` — a closure literal would infer main-actor isolation and fail `@convention(c)` conversion. Use `kFSEventStreamCreateFlagIgnoreSelf` to suppress the app's own writes, but keep a modification-date guard beside it: a self-triggered buffer reload wipes undo history, and `IgnoreSelf` does not cover child processes (for example spawned `git`). FSEvents reports canonical paths (`/private/tmp`, not `/tmp`), so resolve the watched root once with `resolvingSymlinksInPath().standardizedFileURL` and compare raw event paths against it instead of resolving every event path. Do not write live FSEvents tests — they are timing-flaky; unit-test the pure classifier (`WorkspaceChangeClassifier`) and verify the stream manually.

## Testing rules

Use Swift Testing async test functions and await production APIs directly. Do not synchronize with arbitrary sleeps. When UI models require it, mark the focused test `@MainActor` rather than weakening production isolation.

## Verification

```bash
swift build
swift test
rg -n 'Task\.detached|@unchecked Sendable|DispatchQueue|withCheckedContinuation|AsyncStream' Sources Tests
```

Any match is a review target, not automatically a bug. Apply the project-local `swift-concurrency-pro` skill and load only the references relevant to the matched construct.

## Related material

- `Package.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `.agents/skills/swift-concurrency-pro/SKILL.md`
- Phase 0 and later process/remote plans
