# Apple Swift 6.3.3 Release optimizer destructor workaround

- **Applies to:** Generic SwiftUI/AppKit bridge types that cause an Apple Swift
  6.3.3 optimized RafuApp build to crash in `EarlyPerfInliner` while compiling
  a synthesized destructor.
- **Last verified:** Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`), Xcode 26.6,
  macOS 26.5.2 (25F84), 2026-08-16.

## Rule or observed behavior

Keep an explicit empty `deinit {}` on the affected generic hosting view and
nested generic coordinator. It preserves Swift's normal stored-property and
superclass teardown, but changes the generated destructor shape that triggers
the Apple compiler crash.

Do not change optimization settings or add compiler flags. Remove this
workaround only after an optimized RafuApp build succeeds on the affected
toolchain with the explicit destructors removed.

## Why it matters

TG-90 needs an optimized Rafu Lightning build for measurement. The compiler
crash blocked that measurement before an app binary could link. The workaround
is source-local and does not change terminal or HUD behavior.

## Reproduction or evidence

On the stated toolchain, this command crashed with signal 11 in
`EarlyPerfInliner` for the synthesized destructor of
`NotchHUDPassthroughHostingView`:

```bash
swift build --configuration release --product RafuApp
```

After its explicit destructor was added, the same command next crashed in
`TerminalGroupSplitView.Coordinator.deinit`. Adding the same explicit
destructor shape there allowed the optimized RafuApp build to link.

## Verification

```bash
swift build --configuration release --product RafuApp
./script/test.sh --filter ReleaseOptimizerWorkaroundTests
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Terminal/NotchHUDWindow.swift`
- `Sources/RafuApp/Terminal/TerminalGroupSplitView.swift`
- `Tests/RafuAppTests/ReleaseOptimizerWorkaroundTests.swift`
- `docs/plans/phases/terminal-groups/TG-90-integration-qa.md` (Q6)
