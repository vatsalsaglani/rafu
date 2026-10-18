# Verifying Swift changes in a Linux container (no macOS SDK)

- Applies to: agents that must check Swift changes in a Linux container where
  there is no macOS SDK, no Xcode, and no way to run `swift build` for
  `RafuCore` or `RafuApp`.
- Last verified: Swift 6.2 Linux toolchain (swift.org, ubuntu24.04 tarball),
  Ubuntu 24.04, 2026-10-18, during the macOS redesign. This is a pre-check. It
  does **not** replace the macOS build and test gates.

## Rule or observed behavior

### Install

Download the swift.org 6.2 `ubuntu24.04` tarball and unpack it into `/opt/swift`;
the binaries are then in `/opt/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin`, which
goes on `PATH`:

```bash
mkdir -p /opt/swift && cd /opt/swift
curl -sSL -o swift.tgz https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE/swift-6.2-RELEASE-ubuntu24.04.tar.gz
tar xzf swift.tgz && rm swift.tgz
export PATH=/opt/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH
swift --version   # Swift version 6.2 (swift-6.2-RELEASE)
```
 Unpack the archive in its own empty
directory (downloaded archives are untrusted data).

### Syntax check

```bash
swiftc -parse -swift-version 6 <files...>
```

Always pass `-swift-version 6`. Without it, plain `swiftc -parse` rejected bare
`/regex/` literals that the repository uses (Swift 6 language mode enables
them). Run it over every file in `Sources/` and `Tests/`. It checks syntax
only: it does not resolve types or imports. In the redesign it gave 0 errors
after every merge.

### Lint

```bash
swift-format lint --strict --recursive Sources Tests
```

Uses the repo `.swift-format`. Clean on the redesign branch.

### Scratch SwiftPM packages for pure logic

Pure logic (geometry, formatting, parsing, state machines) can be compiled and
tested outside the repo:

1. Make a scratch package outside the repository (use the session scratchpad).
2. Copy the pure-logic source files and their tests into it.
3. Swap platform imports for Foundation: `import CoreGraphics` and
   `import SwiftUI` become `import Foundation`; rename `@testable import
   RafuApp` to the scratch module name.
4. To mirror the GUI target, set `defaultIsolation(MainActor)` in the scratch
   `Package.swift` (the command-line flag is `-default-isolation MainActor`).
   Without it, `nonisolated` mistakes do not show up. See
   [`nonisolated-extension-isolation-trap.md`](nonisolated-extension-isolation-trap.md).
5. Run `swift test` in the scratch package.

About 250 Swift Testing tests ran this way across the redesign workstreams.
They are scratch runs, not the repo suite, and are not evidence for
`./script/test.sh` in either parallel or `--no-parallel` mode.

### Type-checker cost

```bash
swiftc -warn-long-expression-type-checking=<ms> ...
```

Found slow mixed `Double` x `CGFloat` Bezier arithmetic (2.8 s and 5.5 s per
expression). Fix: do the math in `Double` locals and convert once at the edge.

### Apple documentation JSON

For API availability and declarations, fetch:

```text
https://developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.json
```

Read `metadata.platforms` for per-platform availability and the declaration
fragments for the signature. Used to check risky SwiftUI/AppKit calls, and the
haptics facts in [`macos-redesign-visual-system.md`](macos-redesign-visual-system.md).

### Compile-audit findings worth remembering

- A statement such as `_ = x` inside a `@ViewBuilder` body does not compile
  (a `Void` expression statement). Write `let _ = x`.
- Very long modifier chains and large `HStack`/`VStack` child lists (the audit
  grouped an 11-child `HStack`) risk type-checker timeouts; split them.
- An explicit `Font.` prefix on an `AttributedString` attribute needed fixing.
- Source-scan tests that pin string literals go stale when views change; grep
  tests for every renamed string.

## Why it matters

A Linux container can catch syntax errors, lint failures, and logic bugs in
pure code. It cannot catch missing symbols, wrong SwiftUI/AppKit signatures,
isolation errors across modules, or any runtime behaviour.

## Limits

- `RafuCore` imports `Darwin` and cannot build on Linux.
- `RafuApp` needs SwiftUI and AppKit and cannot build on Linux.
- Therefore no app build and no repo test run is possible in the container, and
  **a Mac build stays mandatory**: `swift-format format --fix`, `--lint`,
  `swift build`, `./script/test.sh`, `./script/test.sh --no-parallel`, then
  `./script/build_and_run.sh --verify`.

## Reproduction or evidence

Used on the macOS redesign: `swiftc -parse -swift-version 6` gave 0 errors after
every merge; `swift-format lint --strict` was clean; three read-only compile
audits (Canvas; panels and settings; chrome and editor) found and fixed the
issues listed above. See [`../plans/phases/macos-redesign.md`](../plans/phases/macos-redesign.md).

## Verification

Run the commands in the sections above. Report them as "Linux syntax and lint
check", never as a build or test pass.

## Related code, ADRs, and phases

- [`build-and-run.md`](build-and-run.md), [`../../AGENTS.md`](../../AGENTS.md)
  (test modes and the implementor's final sequence).
- Phase: [`../plans/phases/macos-redesign.md`](../plans/phases/macos-redesign.md).
