# AppKit click tracking loops and synthetic events in tests

- Applies to: click-to-focus code that mixes SwiftUI gestures, `NSEvent` local
  monitors and AppKit-backed subviews (selectable text, scrollers, SwiftTerm, a
  web view); hosted tests that try to send a click. First met in the Ensemble
  card body click (`CanvasBodyClickMonitor`).
- Last verified: Xcode with the macOS 27.2 SDK (26B118), Swift 6 language mode,
  Darwin 27.2.0, Mac17,13, 2026-11-15.

## Rule or observed behavior

1. **A local `NSEvent` monitor is not called for an event that a nested tracking
   loop takes.** An AppKit control that runs its own tracking loop (selectable
   text, scrollers) consumes the mouse-up inside that loop. Use **mouse-down**
   for click-to-focus; do not wait for mouse-up.
2. **SwiftUI simultaneous `TapGesture`s on a container miss a click that an
   AppKit-backed subview takes.** A container tap is not a reliable catch-all
   for a card body that holds AppKit views.
3. **A native self-focus can undo a modifier result.** SwiftTerm and web views
   focus themselves on mouse-down. Apply selection after dispatch (in a `Task`),
   deciding from the state before dispatch, so ⌘ and ⇧ results stay.
4. **Hosted tests: a synthetic `window.sendEvent` click does not drive SwiftUI
   gestures** when the window is not key and the app is inactive. It drives
   AppKit controls only. A test cannot prove a SwiftUI tap this way.
5. **`NSApp.postEvent` in the test runner crashed the runner.** Do not use it.

## Why it matters

A click handler built on mouse-up taps looked correct and failed on exactly the
bodies that contain selectable text or scrollers. A hosted test that sends a
synthetic click can pass or fail for the wrong reason. Keep the decision in a
pure resolver (`CanvasBodyClick`) and test that; check the gesture path by hand.

## Reproduction or evidence

- Evidence is from the code review of the card body click change and the
  hosted-test attempts, as stated in the handoff. No timing or count data was
  recorded.
- Manual: user confirmed in Rafu Lightning that a body click selects and focuses
  each card kind.

## Verification

```bash
./script/test.sh
./script/test.sh --no-parallel
```

Both passed on `main` (3640 tests in 294 suites in each mode). Run the manual
body-click pass in [`canvas-interaction.md`](canvas-interaction.md), "Body
click (2026-11-15)".

## Related code, ADRs, and phases

- `Sources/RafuApp/Canvas/` (`CanvasBodyClickMonitor`, `CanvasBodyClick`).
- [`canvas-interaction.md`](canvas-interaction.md),
  [`swiftui-macos-click-latency.md`](swiftui-macos-click-latency.md),
  [`ensemble-agent-terminal-tools.md`](ensemble-agent-terminal-tools.md) (lease).
- Phase: [`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md).
