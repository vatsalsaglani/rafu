# SwiftUI macOS runtime render and focus tests

## Applies to

Custom macOS SwiftUI rows that put a `Divider` in an aligned overlay, plus
hosted AppKit-window tests that verify SwiftUI focus and first-responder
behavior under the parallel Swift Testing runner.

## Last verified

- macOS 26.5.2 (25F84)
- Xcode 26.6 (17F113)
- Swift 6.3.3

## Overlay-divider rule

Constrain both the width and height of a vertical separator before an opaque
color overlay is applied. A trailing separator can use this shape:

```swift
Divider()
    .frame(width: RafuMetrics.hairline, height: 18)
    .overlay(theme.palette.borderSubtle)
```

Do not assume that `.overlay(alignment: .trailing)` or a height-only frame
gives `Divider` a narrow width.

## Why it matters

An overlay receives its parent's proposal. A `Divider` with only a height can
retain the full proposed width. A following opaque `.overlay(Color)` then
paints that full rectangle. The row still has its correct model identity,
frame, title layout, and hit targets, but the separator color hides all row
content. A selected branch that omits the separator can make the fault look
like inactive rows were removed.

## Reproduction and evidence

WP-71 hosted `EditorCanvasView` with three file tabs. The editor model retained
all three tab resources. Before the width constraint, the first two inactive
tab frames were solid separator color and only the selected title was visible.
After the constraint, the same runtime image contained all three titles. The
regression uses Vision text recognition on the rendered SwiftUI surface so it
checks paint output, not only source structure.

## Hosted focus-test rule

Do not close a newly ordered hosted `NSWindow` at the end of a parallel AppKit
test. Disable its animation, order it out after the assertion, and retain it
for the life of the test process. This keeps the real first-responder path
available without racing AppKit transition disposal against unrelated UI
tests.

The first WP-71 full parallel run passed the focus assertions and then stopped
with `SIGSEGV` in `-[_NSWindowTransformAnimation dealloc]` while another test
was active. The focus test passed alone. With window animation disabled and
the hidden window retained, the hosted focus lifecycle stayed deterministic
without sleeps or polling.

## Verification

```bash
./script/test.sh --filter EditorTabVisibilityPresentationTests
./script/test.sh --filter findBarFocusLifecycle
./script/test.sh --filter EditorTabAndGroupPresentationTests
```

## Related code and plans

- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Tests/RafuAppTests/EditorTabVisibilityPresentationTests.swift`
- `docs/plans/phases/workbench-presentation-upgrade/WP-71-editor-interactions.md`
- ADR 0012, JSON theme authority and rendered theme roles
