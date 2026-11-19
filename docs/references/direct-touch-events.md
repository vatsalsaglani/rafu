# Direct touch on a Mac touch screen

- Applies to: every SwiftUI gesture callback and AppKit event handler that
  reads properties of `NSApp.currentEvent` or of an event it did not
  type-check, on a Mac with a touch screen (macOS 27). First seen on the
  Ensemble board: a finger tap on a card header froze the window.
  Code: `EventClickCount` in `Sources/RafuApp/Support/EventClickCount.swift`,
  `CanvasCardShell.finishClick(at:)` in
  `Sources/RafuApp/Canvas/Views/CanvasCardViews.swift`, and
  `TabClickIntent.current()` in `Sources/RafuApp/Support/TabClickIntent.swift`.
- Last verified: 2026-11-20, Swift 6.4.2, macOS 27.2.1 (26B8132), MacBook Pro
  Mac17,13 (touch screen), macOS 27.2 SDK. Verified from the unified log, the
  SDK headers, the AppKit runtime and AppKit disassembly, and by tests. No
  touch was done on the fixed build.

## Rule

1. Never read `clickCount` (or `eventNumber`, `phase`, `scrollingDeltaX/Y`,
   `magnification`, `pressure`) from an event whose type you did not check
   first. Read the click count only through `EventClickCount.of(_:)` or
   `EventClickCount.current()`. A missing count is one click.
2. In a SwiftUI gesture callback, `NSApp.currentEvent` can be a direct-touch
   event (`NSEvent.EventType.directTouch`, raw value 37), not a mouse event.
   It is not a mouse event with a "touch" subtype.
3. An Objective-C exception raised inside a SwiftUI callback does not crash
   the app. AppKit catches it ("An uncaught exception was raised sending
   gesture action"), but the exception has already unwound through SwiftUI's
   update code. After that the window stops updating while the main thread
   keeps running. For the user this is a hang that only Force Quit ends. No
   hang report was saved, which fits: the main thread was not blocked (it
   kept logging `sendAction:`).

## Why it matters (root cause of the Ensemble touch freeze)

`CanvasCardShell.headerGesture` is a `DragGesture(minimumDistance: 0)`. Its
`onEnded` calls `finishClick(at:)`, which read
`NSApp.currentEvent?.clickCount ?? 1` to tell a double-click. With a mouse the
current event is `leftMouseUp`. With a finger, AppKit routes the touch to
SwiftUI's gesture recognizer from `_NSSendDirectTouchesEvent`, so the current
event is the direct-touch event. `-[NSEvent clickCount]` raised
`NSInternalInconsistencyException`, and the window froze.

`TabClickIntent.current()` had the same fault: it read `clickCount` before it
checked the type. It runs from the tap handler of the Ensemble tab and of the
Terminals panel rows.

## How macOS 27 delivers a direct touch (observed)

- SDK: `NSEventTypeDirectTouch = 37` (available since macOS 10.10).
  `NSView.allowedTouchTypes` defaults to `.direct`. New in
  macOS 27: `NSScreen.touchCapabilities`,
  `NSScrollView.touchScrollingEnabled` (default true) with
  `minimumNumberOfTouchesForScrolling` and
  `scrollGestureForRelationships`, `NSPanGestureRecognizer`
  minimum and maximum touch counts,
  `NSGestureRecognizer.cancellableByScrollGesture`,
  `NSView.exclusiveGestureBehavior`,
  `NSWindow.disablesDirectTouchSystemGestures` (in the runtime, not in the
  public headers), and
  `NSEvent.touchSwipeNavigationEnabled`.
- Runtime: SwiftUI's `SwiftUI.AppKitGestureRecognizer` implements
  `touchesBegan/Moved/Ended/CancelledWithEvent:` beside the mouse methods,
  so SwiftUI gestures (`DragGesture`, `MagnifyGesture`, `onTapGesture`,
  `SpatialTapGesture`) take the finger directly. The crash stack shows the
  path: `_NSSendDirectTouchesEvent` →
  `_NSGestureEnvironmentBase sendTouchesEventToGestureRecognizers:` →
  `_NSGFGestureEnvironment _routeTouchEventToActiveGestureRecognizers:` →
  `NSGestureRecognizer _updateGesture` →
  `SwiftUI.AppKitEventBindingBridge.flushActions` → the gesture's `onEnded`.
- Views that do not take touches get emulated input from
  `_NS3PKitMouseEmulator`: `clickToLeftClick:`, `panToMouseDragged:`,
  `panToScroll:` (scroll events from `_NSTouchScrollWheelEmulator`, which
  has its own momentum session), `pressToLeftDrag:`, `pressToRightDrag:`,
  `magnificationToPinch:`, `rotationToPinch:`. Which one a view gets depends
  on its `_gestureRecognizersViewConfigForMouseEmulation`; `NSTableView`,
  `NSTextView`, `NSControl`, `NSTextField`, `WKWebView` and SwiftUI's
  scroll container override it. Rafu does not depend on these private names;
  they explain why a finger can reach the board as a gesture, a click, or a
  scroll.
- `-[NSEvent clickCount]` in AppKit 27.2 answers only for types 1 to 7
  (left and right mouse, mouse moved and drags), 25 to 27 (other mouse) and
  40 (mouse cancelled), mask `0x0100_0E00_00FE`. Every other type raises,
  direct touch included. A test cannot make a direct-touch `NSEvent`:
  `NSEvent(cgEvent:)` refuses type 37.

## Reproduction or evidence

The user's two force-quit runs of the release app (2026-11-19 23:41:30 and
2026-11-20 00:11:31) logged the same exception, with frame 4
`CanvasCardShell.finishClick(at:)` and frame 3 `-[NSEvent clickCount]`:

```bash
/usr/bin/log show --last 2d --style compact \
  --predicate 'process == "Rafu" AND (messageType == error OR messageType == fault)' \
  | grep -A40 "Assertion failure in <private>, NSEvent.m"
```

(In zsh call `/usr/bin/log`: `log` is a shell builtin.) In both runs the main
thread logged `sendAction:` for minutes after the exception, and the render
log showed `RBLayer: full image queue` and `RBDrawable: no surface, dropping
frame`. The process was alive, but the window did not update.

The raise for non-mouse types can be checked with a small Objective-C probe
that calls `clickCount` on key, application-defined and scroll events inside
`@try`.

## Verification

```bash
swift test --filter EventClickCountTests
swift test --filter TabInteractionResponsivenessTests
```

`EventClickCountTests` checks the type table against the AppKit mask, that
key, scroll and application-defined events give one click without a raise (a
raise stops the test process), that mouse events keep their count, and that
no source reads `currentEvent?.clickCount` directly.

Manual, on a Mac with a touch screen: open an Ensemble, tap a card header with
a finger, tap it again, drag a card, pan the board with one finger, pinch to
zoom, tap the Ensemble tab and a Terminals panel row. The window must keep
updating. A finger double tap on a header counts as one tap (there is no click
count for a touch), so it selects the card and does not rename or zoom.

## Related code, ADRs, and phases

- `Sources/RafuApp/Canvas/Views/CanvasCardViews.swift` (`headerGesture`,
  `finishClick`), `Sources/RafuApp/Canvas/Views/CanvasEditorTabItem.swift`,
  `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`,
  `Sources/RafuApp/Views/WindowDragAttachment.swift` (already type-checks
  before it reads `clickCount`).
- [`canvas-interaction.md`](canvas-interaction.md) (board input map, scroll
  routing), [`swiftui-macos-click-latency.md`](swiftui-macos-click-latency.md)
  (the one-tap-handler `TabClickIntent` pattern).
