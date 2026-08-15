# Headless `NSWindow` lifecycle tests

**Applies to:** Headless AppKit tests that verify window style masks or window
chrome across full-screen changes.
**Last verified:** macOS 26.5.2 (Darwin 25), Xcode 26.6, Apple Swift 6.3.3,
2026-08-15.

## Rule

Do not insert or remove `NSWindow.StyleMask.fullScreen` directly in a headless
test. AppKit raises `NSGenericException` because only the full-screen transition
methods can change that style-mask bit.

Test the stable pre-transition and post-transition chrome invariants with a
headless `NSWindow`. Test the transition itself with a real app window through
`toggleFullScreen(_:)` during the shared GUI verification pass.

When a test replaces `window.contentView`, do not read the replacement view's
base titlebar safe area before the flat style mask is restored. In this setup,
the new view first reported zero and reported the real 32-point base inset only
after `.fullSizeContentView` was inserted. Assert the post-apply relation
instead: `base = effective - additional`, `additional == -base`, and effective
top safe area is zero.

## Why it matters

A direct style-mask mutation looks like a small test setup step, but it aborts
the test process before an assertion can run. It does not model AppKit's window
replacement and titlebar reset work during a real full-screen transition.

## Reproduction and evidence

This setup raised `NSGenericException` while extending
`FlatWindowChromeTests`:

```swift
window.styleMask.insert(.fullScreen)
```

The exception states that a full-screen style mask can only be set by a
full-screen transition. The WP-72 regression therefore drives the shared chrome
reapply seam directly in headless tests and keeps the real transition in the
manual matrix.

The same regression replaces the current content view and records the base,
additional, and effective top safe-area values after the repair. On the stated
toolchain it recorded a 32-point base inset, a -32-point additional inset, and
a zero effective inset.

## Verification

```bash
./script/test.sh --filter 'FlatWindowChrome|WindowChromeTopologyLifecycle'
./script/build_and_run.sh --verify
```

After launch, enter and leave full screen. Confirm that the title stays hidden,
the titlebar stays transparent, the separator stays absent, the top safe area
stays zero, and no native band appears during or after the transition.

## Related

- `Sources/RafuApp/Views/FlatWindowChrome.swift`
- `Tests/RafuAppTests/FlatWindowChromeTests.swift`
- `Tests/RafuAppTests/WindowChromeTopologyLifecycleTests.swift`
- ADR 0012 and
  `docs/plans/phases/workbench-presentation-upgrade/WP-72-window-chrome-lifecycle.md`
