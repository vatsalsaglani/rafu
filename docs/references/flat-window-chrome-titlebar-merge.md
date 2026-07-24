# Flat window chrome: merging content with the titlebar zone

**Applies to:** `Sources/RafuApp/Views/FlatWindowChrome.swift`,
`Sources/RafuApp/Views/WorkspaceWindowView.swift`,
`WindowTopLeftControlCluster`/`WorkspaceSidebarRail` in
`Sources/RafuApp/Views/WorkspaceNavigatorView.swift`.
**Last verified:** macOS 26 (Darwin 25.5.0), Swift 6.2, 2026-07-25, via the
throwaway TitleBarProto spike and the shipped implementation.

## Rules

1. **`fullSizeContentView` + `titlebarAppearsTransparent` alone leave a dead
   band.** SwiftUI still reserves the titlebar zone as top safe area, so the
   window shows an empty painted strip above the content. SwiftUI **does**
   render real content in that zone once the safe area is gone — an earlier
   note in `FlatWindowChrome` claimed only backgrounds bleed there; that was
   only true of content that respects the top safe area.

2. **Cancel the titlebar safe area at the WINDOW level, never with
   per-view `.ignoresSafeArea`.** `FlatWindowChrome.cancelTitlebarSafeArea`
   sets `contentView.additionalSafeAreaInsets.top` to the negative of the
   base titlebar inset, so every hosting view in the window reports a zero
   top safe area (no-op in full screen, where the base is already 0).
   View-level `.ignoresSafeArea` escapes are NOT a workable substitute in
   this window: every `HSplitView` pane is its own AppKit hosting view that
   re-derives the window safe area on its own schedule, so any fixed
   arrangement of per-pane escapes drifts between under-correction (tab
   strip a titlebar-height too low) and over-correction (tab strip pushed
   above the window's top edge) across open/full-screen/refocus events.
   Verified by the TitleBarProto strategy comparison: only the
   window-level cancellation held `top inset 0` in every pane across
   launch, full-screen round trip, and unfocus.

3. **`_NSTitlebarDecorationView` paints an opaque band over an INACTIVE
   window** on macOS 26 even with a transparent titlebar.
   `titlebarAppearsTransparent` manages `NSTitlebarBackgroundView` but not
   this private decoration view. `FlatWindowChrome` hides it (and any
   glass/visual-effect/backdrop companions) by class-name match inside
   `NSTitlebarContainerView`, never touching `NSButton`s (the traffic
   lights). The scrub sets `isHidden = true` **and** `alphaValue = 0`:
   AppKit flips `isHidden` back during window-state transitions (sheet
   presentation such as the command palette, key changes), which flashed
   the band for milliseconds until the next notification-driven scrub —
   but it does not restore `alphaValue`, so zero alpha covers the gap.

3a. **Interactive content in the titlebar zone drags the whole window.**
   The titlebar's implicit drag region sits under the tab strip, so a tab
   drag (or drag-to-split) also moved the window. `FlatWindowChrome` sets
   `isMovable = false` and window movement is opt-in via `WindowDragHandle`
   (a `WindowDragGesture` surface, which bypasses `isMovable`): the left
   rail, the utility rail's background, the sidebar header's background,
   and the breadcrumb's background. The tab strip itself cannot host a
   handle — its `ScrollView` swallows background hits. Known tradeoffs:
   the strip's empty trailing area does not move the window, and
   titlebar double-click-to-zoom is lost (zoom stays available via the
   traffic lights and the Window menu).

4. **A full-screen round trip recreates the decoration view *after* the
   transition notification fires.** A single immediate re-apply on
   `didExitFullScreen` misses it, and the band reappears the next time the
   window goes inactive — this presented as "the ugly bar comes back after
   some time". `FlatWindowChrome` therefore re-applies chrome on
   enter/exit-full-screen, become/resign-key, and become/resign-main, **and
   again on delayed passes (0.05 s / 0.3 s / 1 s)** after each notification.
   The delayed passes are the part that actually fixes it; do not remove
   them as "redundant".

5. **Traffic lights hover-reveal.** Outside full screen the lights stay
   hidden (`standardWindowButton(_:).isHidden` — hidden, never removed, so
   close/zoom and their accessibility actions keep working) until the
   pointer enters `WindowTopLeftControlCluster`, which then widens by the
   76 pt light span and slides the sidebar toggle right. In full screen the
   system owns the lights; `FlatWindowChrome` reports transitions via
   `onFullScreenChange` so the cluster drops its inset and hover tracking.

6. **Keep the collapsed hover zone narrow.** The cluster is exactly
   rail-width while the lights are hidden; a wider invisible hover zone
   would swallow clicks aimed at the sidebar header's leading edge at
   minimum sidebar width.

## Why it matters

The pre-merge look (empty dark strip above the sidebar) read as dated
against cmux/VS Code/Warp-class tools, and the inactive-window band broke
the flat chrome ADR 0012 promises. Both fixes live entirely in the existing
AppKit escape hatch — no toolbar, no custom window subclass.

## Verification

- `swift test` — `FlatWindowChromeTests` covers the chrome invariants,
  separator removal, traffic-light hiding, initial full-screen reporting,
  and the backdrop class matcher.
- `./script/build_and_run.sh --verify`, then by hand: hover top-left
  (lights fade in, toggle slides right), full-screen round trip, unfocus
  the window (no band), second window, ⌘B both from menu and toggle.
- The decoration-view hierarchy can be inspected by dumping
  `window.contentView?.superview` subviews whose class name contains
  `Titlebar` (see the TitleBarProto spike technique).

## Known limitation

With the sidebar collapsed, a revealed cluster transiently overlays the
leading ~106 pt of the editor tab strip while the pointer is in the
top-left corner. Tabs are never covered while the pointer is over them
(leaving the cluster hides the lights again), but a pointer sweeping
through the corner can flash the lights over the first tab.

## Related

- ADR 0012 (flat workbench chrome), ADR 0002 (single sidebar toggle).
- `docs/references/ui-design-language.md` — earlier titlebar treatment
  (`.toolbarBackground(.hidden)`) superseded by this recipe.
- `Tests/RafuAppTests/FlatWindowChromeTests.swift`.
