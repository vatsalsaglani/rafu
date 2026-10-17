# `nonisolated` does not propagate into a bare `extension` under default-`MainActor` isolation

- Applies to: Swift 6.2 and Swift 6.4 targets compiled with `.defaultIsolation(MainActor.self)`
  (`RafuApp`), specifically pure `static`/`func` members declared inside a
  plain `extension` of a `nonisolated` type
- Last verified runtime evidence: Swift 6.2, macOS 26, 2026-07-22
- Last verified compiler evidence: Swift 6.4 (swiftlang-6.4.0.34.1),
  macOS 27.0.1 (26A434), 2026-10-17

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

The failure can appear at compilation or runtime. In the original Swift 6.2
case, the code built cleanly and failed at runtime when the
inferred-MainActor member executed off the main actor/thread — for
example inside a closure passed to `Array.map` on a background/test
thread, or inside an actor's synchronous helper. The process crashed with
`SIGTRAP` / `EXC_BREAKPOINT` via `dispatch_assert_queue_fail`, the same
executor-mismatch trap documented for `DispatchSource` handlers in
[`concurrency.md`](concurrency.md). That case had a crash-report backtrace
without a compiler diagnostic. It does not establish that all call sites
or later toolchains omit diagnostics.

The Swift 6.4 integration test build on 2026-10-17 rejected six synchronous
calls from nonisolated `GitTreeBadgeTests` to
`GitSnapshot.treeBadges(workspaceRoot:)`. The diagnostic was
`call to main actor-isolated instance method 'treeBadges(workspaceRoot:)' in a synchronous nonisolated context`
(`ActorIsolatedCall`). One call was inside a `#expect` macro expansion; the
other five were ordinary calls before their assertions. The method lives in
a bare extension of the nonisolated, Sendable `GitSnapshot` value type.
This is compile-time evidence, not a new runtime crash reproduction.

The next test compile rejected four nonisolated accesses to `ServerPack.all`
in `ServerPackTests`. This static catalog is an immutable array of Sendable
values in a bare extension of `ServerPack`. Mark the static property
`nonisolated`; adding actor hops at each test call site would preserve an
unnecessary API restriction. Remove the temporary `await` from the local ID
read in `LanguageServersCatalogModelTests` after this repair.

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

For a narrow repair, mark only the pure member `nonisolated`:

```swift
extension GitSnapshot {
  nonisolated func treeBadges(workspaceRoot: URL) -> [String: GitTreeBadge] { ... }
}
```

The badge method reads immutable snapshot fields, standardizes URL values,
and builds a local dictionary. It does not read UI state, perform file I/O,
or change shared state. Keep its synchronous nonisolated tests; making the
tests main-actor-isolated would hide the incorrect API boundary.

## Why it matters

This cost real debugging time during the Notch Companion NC-A stage: a
pure static declared in a bare extension of a `nonisolated` model type
silently became `@MainActor`-isolated, then trapped the first time a test
called it from a closure running off the main thread.

Some call sites can pass compilation and still fail at runtime. Review the
isolation boundary and exercise the code path off-main; do not use a passing
build alone as proof. Other call sites, such as the Swift 6.4 badge tests,
can expose the incorrect boundary during compilation.

## Reproduction or evidence

Confirmed via a macOS crash-report backtrace showing
`dispatch_assert_queue_fail` originating from the inferred-`@MainActor`
extension member when invoked from a non-main-actor closure (e.g. inside
`.map` on a test-harness thread), during NC-A implementation and fixed by
moving the static into the type's primary declaration.

The 2026-10-17 compiler evidence is in
`/tmp/rafu-repair-20261017/initial-tests.log`, lines 516–638. The integration
build stopped before tests ran. After removing repeated batch-command
failures, all six real error diagnostics identify the badge method's
isolation. The source repair and static lint do not establish a passing
build; integration must compile and run `GitTreeBadgeTests` again.
The catalog diagnostics are in `/tmp/rafu-repair-20261017/second-tests.log`,
lines 76–140. All four real errors name `ServerPack.all`. These logs do not
establish that the repairs pass compilation or tests.

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

- `Sources/RafuApp/Models/GitTreeBadge.swift` and `Tests/RafuAppTests/GitTreeBadgeTests.swift` — Swift 6.4 compiler case
- `Sources/RafuApp/Terminal/TerminalShellCatalog.swift` (correct pattern:
  pure statics in the primary body)
- `Sources/RafuApp/Notch/NotchHUDPolicy.swift` (correct pattern)
- [`concurrency.md`](concurrency.md) — the sibling `DispatchSource`
  executor-mismatch trap (same `dispatch_assert_queue_fail` failure
  signature, different root cause)
- [`notch-companion.md`](notch-companion.md) — NC-A implementation where
  this was found
- [`terminal-notch-hud.md`](../plans/phases/terminal-notch-hud.md)

## Additional integration evidence, 2026-10-17

The Swift 6.4 test compiler also rejected `NotchHUDGeometry.bandInset(for:)`
from a nonisolated test. The enum is nonisolated, but this method is in a
separate extension. Adding `nonisolated` to this pure method preserves its
runtime behavior and makes its intended isolation explicit. The diagnostic is
in `/tmp/rafu-repair-20261017/repair-tests-5.log`. Recheck with
`./script/test.sh --filter hudFrameBelowNotch`.
