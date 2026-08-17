# NSSplitView divider position quantization

- **Applies to:** `NSSplitView` divider callbacks and headless split-view tests
- **Last verified:** Apple Swift 6.3.3, Xcode 26.6, macOS 26.5.2, and the GitHub `macos-26` runner on 2026-08-17

## Rule or observed behavior

Treat the coordinate passed to `NSSplitView.setPosition(_:ofDividerAt:)` as a
requested position. AppKit can align the resulting subview frame to a backing
coordinate. The final position can therefore differ from the request by less
than one point, and the exact difference can vary between local and hosted
macOS environments.

A divider callback must report the normalized fraction of the final live
subview frame. Tests must compare that callback with the live frame. A test can
also prove that the live frame stays within one point of the requested
coordinate. Do not compare the callback with the requested normalized fraction
through a sub-point fixed epsilon.

## Why it matters

A fixed normalized epsilon can encode an accidental display-scale assumption.
The Terminal Group divider test used a tolerance of `0.001`, which allowed only
`0.2` point at its `200`-point usable length. It passed locally but failed on a
GitHub `macos-26` runner after AppKit returned a valid live fraction of
`0.6979166667` for a requested fraction of `0.7`.

Saving the requested fraction would also make the snapshot disagree with the
visible divider. The callback must preserve the final AppKit position that the
user sees.

## Reproduction or evidence

1. Create a vertical `NSSplitView` with a `200`-point usable length.
2. Request a divider position at fraction `0.7`.
3. Read the first arranged subview's final width.
4. On the hosted runner, the normalized final width was `0.6979166667`. The
   difference from the request represented less than one AppKit point.
5. The same test produced exactly `0.7` in the local environment.

## Verification

```bash
./script/test.sh --filter 'TerminalGroupSplitViewTests.dividerTrackingDoesNotSnapBack'
./script/test.sh --filter 'TerminalGroupSplitViewTests'
```

The focused test must prove that one callback is emitted, the callback maps
back to the live first-subview length, and the live divider remains within one
point of the requested position.

## Related code, ADRs, and phases

- `Sources/RafuApp/Terminal/TerminalGroupSplitView.swift`
- `Tests/RafuAppTests/TerminalGroupSplitViewTests.swift`
- `docs/decisions/0023-terminal-groups-and-saved-layouts.md`
- `docs/plans/phases/terminal-groups/TG-21-renderer-focus.md`
