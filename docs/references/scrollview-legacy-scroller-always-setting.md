# `.scrollIndicators(.hidden)` does not remove the legacy `NSScroller` under "Show scroll bars: Always"

- Applies to: any SwiftUI `ScrollView` in `RafuApp` rendered on a Mac with
  System Settings → Appearance → "Show scroll bars" set to "Always" (rather
  than the default "Automatically based on mouse or trackpad")
- Last verified: Swift 6.2, macOS 26.5 (deployment target `.macOS(.v15)` in
  `Package.swift`), 2026-07-24

## Rule or observed behavior

SwiftUI's `.scrollIndicators(.hidden)` only hides the OVERLAY scroll
indicator that SwiftUI itself draws. It does not reach into the underlying
AppKit `NSScrollView` that backs the `ScrollView` on macOS. When the user's
system preference is "Always" (non-overlay/legacy scrollers), the
`NSScrollView` still has `hasHorizontalScroller`/`hasVerticalScroller` set to
`true` by default and draws a real ~15pt `NSScroller`, regardless of the
`.scrollIndicators(.hidden)` modifier applied in SwiftUI. In a horizontally
scrolling editor tab strip (`EditorGroupTabBar`, 28pt tall
`RafuMetrics.tabBarHeight`), that scroller visibly ate into the tab-strip
chrome and looked broken.

**Fix:** force the legacy scroller off directly on the `NSScrollView` via a
small `NSViewRepresentable` "configurator" (`ScrollerHidingConfigurator` in
`Sources/RafuApp/Support/ScrollViewConfigurator.swift`) that walks
`nsView.enclosingScrollView` and sets `hasHorizontalScroller = false` /
`hasVerticalScroller = false`. Keep `.scrollIndicators(.hidden)` too — it
still matters for the overlay case on "Automatically" — but it is not
sufficient by itself under "Always".

**Attachment-point caveat:** attach the configurator as a zero-size
`.background(ScrollerHidingConfigurator())` on the CONTENT view placed
INSIDE the `ScrollView` (e.g. the scrolled `HStack`), not on the
`ScrollView` itself. Only the content view's `enclosingScrollView` reliably
resolves to the actual `NSScrollView` once the hierarchy is attached; a
representable placed directly on `ScrollView` sees a different level of the
view tree. `enclosingScrollView` can also be `nil` on the very first
`updateNSView` call before the hierarchy is fully attached — reapplying once
more via `DispatchQueue.main.async` in `updateNSView` catches that case
without polling indefinitely. In this integration, the `.background`
placement resolved `enclosingScrollView` correctly on the synchronous call
already; the async reapply is a defensive backstop for the first-attach
race, not something observed to be strictly required for the tab strip.

## Why it matters

The bug reproduces only when a real Mac's system-wide scroll-bar preference
is "Always" — the default "Automatically based on mouse or trackpad" masks
it entirely (the overlay indicator SwiftUI hides is the only one drawn).
This makes it easy to ship a horizontal `ScrollView` that looks correct in
every normal manual check and Simulator/Preview pass, then appears broken
specifically for users who have opted into always-visible scroll bars
(a documented, if less common, macOS accessibility/preference choice). Any
future horizontally (or vertically) scrolling `ScrollView` added to chrome
this thin — tab bars, pill strips, breadcrumb strips — is at risk of the
same regression and should apply the same configurator.

## Reproduction or evidence

1. System Settings → Appearance → "Show scroll bars" → "Always".
2. Open enough editor tabs in one group to overflow `EditorGroupTabBar`'s
   width.
3. Before the fix: a horizontal `NSScroller` is visibly drawn inside the
   28pt tab strip alongside `.scrollIndicators(.hidden)` already applied.
4. After attaching `ScrollerHidingConfigurator()` to the scrolled `HStack`'s
   `.background`: no scroller draws under "Always", and the tab strip
   remains horizontally scrollable via trackpad/scroll wheel and the new
   overflow `Menu`.

## Verification

```bash
swift build
swift test
./script/format.sh --lint
./script/build_and_run.sh --verify
```

`swift test` has no pure-logic surface to unit-test here (this is an AppKit
scroller flag toggle, not a computation); no new unit test was added for
this fix. Full confirmation that no scroller draws under "Always" across
both themes is a manual GUI check, not automatable from `swift test`.

## Related code, ADRs, and phases

- `Sources/RafuApp/Support/ScrollViewConfigurator.swift` —
  `ScrollerHidingConfigurator`
- `Sources/RafuApp/Views/EditorCanvasView.swift` — `EditorGroupTabBar`,
  where the configurator is attached to the scrolled `HStack`'s
  `.background`, and the new trailing overflow `Menu` that keeps every tab
  reachable while the strip stays horizontally scrollable
- [`pre-initial-push-workbench.md`](../plans/phases/pre-initial-push-workbench.md)
  — active phase covering polished workbench navigation/chrome
