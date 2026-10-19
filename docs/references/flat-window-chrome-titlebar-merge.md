# Flat window chrome: merging content with the titlebar zone

**Applies to:** `Sources/RafuApp/Views/FlatWindowChrome.swift`,
`Sources/RafuApp/Views/WorkspaceWindowView.swift`,
`WindowTopLeftControlCluster` in
`Sources/RafuApp/Views/WorkspaceNavigatorView.swift`
(`WorkspaceSidebarRail` was removed on 2026-10-19; see "No left rail" below).
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
   rail (removed 2026-10-19), the utility rail's background, the sidebar
   header's background, and the breadcrumb's background. The current list
   is in "No left rail" below. The tab strip itself cannot host a
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

5. **Traffic lights hover-reveal (SUPERSEDED by the macOS redesign; macOS
   build verification pending).** The traffic lights are now always visible. A
   new 28 pt `WindowTitlebarRow` with a plain sidebar toggle replaced the hover
   cluster, so rules 5 and 6 and the "Known limitation" below describe the
   removed behaviour and are kept as history. Original text: Outside full screen the lights stay
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

## Titlebar row (2026-10-18)

Last verified: Swift 6.2 Linux read-through, 2026-10-18; not yet run on macOS.

`Sources/RafuApp/Views/WorkspaceTitlebarRow.swift` defines `WindowTitlebarRow`,
the 28 pt row that replaced the hover cluster:

- Centre: a workspace menu (recents, saved workspaces, Open Folder, Open
  Workspace, Add Folder to Workspace, Save Workspace As, Show All Workspaces,
  Reveal in Finder), a branch chip, and an agent activity capsule shown only
  while agents run (opens the Terminals panel; text carries the meaning, not the
  gold dot alone).
- Trailing: a Search button (opens the palette, shown as ⌘P).
- Everything else is a drag surface (`TitlebarDragSurface`, `WindowDragGesture`).
  A double-click calls `TitlebarDoubleClick.perform(in:)`, which follows
  `TitlebarDoubleClickAction.current()` (zoom, minimise, or none). The window
  comes from the click event, so a second window never zooms the first. It does
  nothing in full screen or with a sheet attached. This restores the
  double-click-to-zoom that rule 3a recorded as lost, for this row only.
- `WindowTitlebarRow` has an explicit `init(session:isFullScreen:)`. A private
  stored property would make the synthesized memberwise init private on
  Swift 6.3 (the source comment states this; it was not compiled here).

## `applyChrome` is idempotent (2026-10-19)

`applyChrome(to:)` in `FlatWindowChrome.swift` runs on every tab switch (one
immediate pass plus three delayed ones). It assigns `isMovable`,
`.fullSizeContentView`, `titlebarAppearsTransparent`, `titleVisibility`,
`titlebarSeparatorStyle`, and `backgroundColor` only when the value differs
from the window's live value, because each AppKit setter can invalidate the
titlebar or the window. The result is the same as before; a repeated pass does
no work. Keep any new window write behind the same comparison. Context and the
other tab-click causes: [`swiftui-macos-click-latency.md`](swiftui-macos-click-latency.md).
macOS 27.0.1 (26A434), 2026-10-19; not measured, so no latency gain is claimed.

## No left rail (2026-10-19)

Last verified: Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1 (26A434),
2026-10-19, on `main`. A person has not yet looked at the window.

The user reported that a collapsed Files sidebar left an empty ~40 pt
full-height strip with a hairline, and then asked for the expanded state:
"why have that left part still empty we can just move the content to that".

- `WorkspaceSidebarRail` and its `Divider` are deleted.
  `WorkspaceWindowView.workbenchContent` puts the `HSplitView` directly under
  the titlebar row, and the Files pane is gated once by
  `if !session.isSidebarCollapsed`.
- Expanded: the Files header (10 pt horizontal padding,
  `WorkspaceSidebarView.swift:131`) and the tree rows (8 pt leading inset)
  start at the window's left edge. Collapsed: the workbench deck starts at the
  left edge.
- **No left icon rail replaces it.** ADR 0003 puts every navigator mode on the
  right rail, so the left side hosts Files only; a left icon rail would carry
  one icon that duplicates the single sidebar toggle ADR 0002 requires. The
  toggle and the traffic lights stay in `WindowTitlebarRow`; the hover-revealed
  traffic lights are not coming back (rule 5 — the revealed cluster covered the
  tab strip).
- **Drag surfaces after the removal.** `isMovable` is still false. The window
  drags from the `TitlebarDragSurface` behind the 28 pt `WindowTitlebarRow` and
  from the Files sidebar header's own `.background(WindowDragHandle())`
  (`WorkspaceSidebarView.swift:138`). The left edge below the titlebar row is
  no longer a drag surface. Check this list before removing another
  background-level drag handle.

Evidence: `WorkbenchDeckPresentationTests` `noLeftRailBesideFilesSidebar`
(asserts no `WorkspaceSidebarRail` and exactly one
`if !session.isSidebarCollapsed`), `structuralPlaneStaysOutsideDeck`
re-anchored on Files / utility rail / status, and
`WorkspaceUntitledDocumentTests.sidebarCollapseStateIsPerSession`.
Gates on `main`: `./script/format.sh --lint` clean; build with 0 new warnings;
parallel suite 250 + 2545 tests passed; `--no-parallel` (CI mode) 250 + 2545
passed; `./script/build_and_run.sh --verify` passed for Rafu Lightning.
Still open by hand: the left edge in both sidebar states, in light, dark, and
Increase Contrast, and in a second window.

## Why it matters

The pre-merge look (empty dark strip above the sidebar) read as dated
against cmux/VS Code/Warp-class tools, and the inactive-window band broke
the flat chrome ADR 0012 promises. Both fixes live entirely in the existing
AppKit escape hatch — no toolbar, no custom window subclass.

## Verification

- `swift test` — `FlatWindowChromeTests` covers the chrome invariants,
  separator removal, traffic-light hiding, initial full-screen reporting,
  and the backdrop class matcher.
- `./script/build_and_run.sh --verify`, then by hand: check the lights are
  always visible and the `WindowTitlebarRow` toggle works (the old hover
  check is obsolete; not yet run on macOS), full-screen round trip, unfocus
  the window (no band), second window, ⌘B both from menu and toggle.
- The decoration-view hierarchy can be inspected by dumping
  `window.contentView?.superview` subviews whose class name contains
  `Titlebar` (see the TitleBarProto spike technique).

## Known limitation (obsolete: describes the removed hover cluster)

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
