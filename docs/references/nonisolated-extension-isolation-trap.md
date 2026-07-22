# `nonisolated` does not propagate into a bare `extension` under default-`MainActor` isolation

- Applies to: any Swift 6.2 target compiled with `.defaultIsolation(MainActor.self)`
  (`RafuApp`), specifically pure `static`/`func` members declared inside a
  plain `extension` of a `nonisolated` type
- Last verified: Swift 6.2, macOS 26, 2026-07-22

## Rule or observed behavior

Marking a type `nonisolated` (or defining it in a nonisolated module) does
not make members declared in a separate, bare `extension` of that type
nonisolated too. Under a target's default `MainActor` isolation
(`RafuApp`'s `.defaultIsolation(MainActor.self)`), the Swift compiler
infers `@MainActor` isolation for members declared in an `extension`
unless the extension itself is explicitly marked `nonisolated` (or
`@MainActor`-free isolation is otherwise established for that extension).
This applies even to pure, stateless `static` functions/properties that
never touch actor-isolated state.

The trap is that this is **not a compile error**. The code type-checks
and builds cleanly. It only fails at **runtime**, the first time the
inferred-MainActor member executes off the main actor/thread — for
example inside a closure passed to `Array.map` on a background/test
thread, or inside an actor's synchronous helper. The process crashes with
`SIGTRAP` / `EXC_BREAKPOINT` via `dispatch_assert_queue_fail`, the same
executor-mismatch trap documented for `DispatchSource` handlers in
[`concurrency.md`](concurrency.md). There is no compiler diagnostic
pointing at the cause; only a crash-report backtrace.

**Fix:** declare pure statics that must be usable off-main in the type's
PRIMARY body, not in a separate bare `extension` — as
`TerminalShellCatalog` and `NotchHUDPolicy` do. If the member must live in
an extension (e.g. for file organization), mark that extension
`nonisolated` explicitly:

```swift
nonisolated extension SomePureType {
  static func pureHelper() -> Int { ... }
}
```

## Why it matters

This cost real debugging time during the Notch Companion NC-A stage: a
pure static declared in a bare extension of a `nonisolated` model type
silently became `@MainActor`-isolated, then trapped the first time a test
called it from a closure running off the main thread. Because the failure
mode is a runtime crash rather than a compile error, it will not be
caught by code review or the type checker — only by actually exercising
the code path off-main (a headless test that maps/reduces over the type,
or Instruments/crash-report evidence).

## Reproduction or evidence

Confirmed via a macOS crash-report backtrace showing
`dispatch_assert_queue_fail` originating from the inferred-`@MainActor`
extension member when invoked from a non-main-actor closure (e.g. inside
`.map` on a test-harness thread), during NC-A implementation and fixed by
moving the static into the type's primary declaration.

## Verification

```bash
# Grep for pure statics living in bare extensions of nonisolated types —
# review each hit for whether it can run off-main.
rg -n "^extension .+\{" Sources/RafuApp | grep -v "nonisolated extension"
swift build
swift test
swift test --no-parallel
```

Any extension of a `nonisolated` type that is not itself marked
`nonisolated` is a review target under `RafuApp`'s default-`MainActor`
isolation.

## Related code, ADRs, and phases

- `Sources/RafuApp/Terminal/TerminalShellCatalog.swift` (correct pattern:
  pure statics in the primary body)
- `Sources/RafuApp/Notch/NotchHUDPolicy.swift` (correct pattern)
- [`concurrency.md`](concurrency.md) — the sibling `DispatchSource`
  executor-mismatch trap (same `dispatch_assert_queue_fail` failure
  signature, different root cause)
- [`notch-companion.md`](notch-companion.md) — NC-A implementation where
  this was found
- [`terminal-notch-hud.md`](../plans/phases/terminal-notch-hud.md)
