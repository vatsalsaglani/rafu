# `enumerated()` collection conformance has a deployment availability boundary

- **Applies to:** SwiftUI `ForEach` and other APIs that require a
  `RandomAccessCollection` when their input comes from `Collection.enumerated()`
- **Last verified:** Apple Swift 6.3.3, Xcode 26 SDK, macOS 26.5.2 host, Rafu
  macOS 15 deployment target, 2026-08-15

## Rule or observed behavior

Do not pass `collection.enumerated()` directly to SwiftUI `ForEach` in code
that deploys before macOS 26. Wrap the bounded sequence in
`Array(collection.enumerated())`, or use a separate stable value model that
stores the position.

The Swift toolchain supports direct `enumerated()` collection use, but its
`RandomAccessCollection` conformance is available only on macOS 26. The source
can compile for the macOS 26 host and still fail the package build because
Rafu's declared deployment target is macOS 15.

The array wrapper is suitable only when the collection is known to be small or
the eager copy is otherwise measured and accepted. For an unbounded or hot
list, store the position in a stable row value instead of copying the full
collection during view evaluation. The row identity must still come from the
element, not the offset.

## Why it matters

Toolchain support and deployment availability are separate. Guidance that says
the direct `enumerated()` form works in Swift 6.1 or later is incomplete for a
package with an older Apple-platform deployment target. The compiler reports
the availability error at the surrounding SwiftUI view-builder nodes, which
can make the fault look larger than the single `ForEach` input.

## Reproduction and evidence

This form failed in `TerminalShellPickerView`:

```swift
ForEach(shells.enumerated(), id: \.element.path) { index, shell in
    // row
}
```

The compiler reported:

```text
conformance of 'EnumeratedSequence<Base>' to 'RandomAccessCollection'
is only available in macOS 26.0 or newer
```

The macOS 15-compatible bounded form compiled:

```swift
ForEach(Array(shells.enumerated()), id: \.element.path) { index, shell in
    // row
}
```

The shell path remains the identity. The offset is row data only.

## Verification commands

```bash
swift --version
./script/build.sh
./script/test.sh --filter TerminalShellPickerPresentation
```

## Related code and plans

- `Sources/RafuApp/Views/TerminalShellPickerView.swift`
- `Tests/RafuAppTests/TerminalShellPickerPresentationTests.swift`
- `docs/plans/phases/workbench-presentation-upgrade/WP-74-terminal-hierarchy-picker.md`
