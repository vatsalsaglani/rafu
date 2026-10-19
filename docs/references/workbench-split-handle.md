# Workbench split handle: a custom sidebar/deck boundary instead of `NSSplitView`

- **Applies to:** the boundary between the left sidebar and the editor deck in
  the workspace window — `WorkbenchSplitHandle`, `WorkbenchSidebarResize`,
  `WorkspaceSession.sidebarWidth` / `isSidebarCollapsed`, and
  `RestorableWorkspace`.
- **Last verified:** Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
  (26A434), 2026-10-19, on `main` 96e54b3. Gates listed under Verification. A
  person has not yet dragged the handle.

## Rule or observed behavior

The outer `HSplitView` is gone. The workbench is now

```
HStack { activity rail ; sidebar at session.sidebarWidth ; WorkbenchSplitHandle ; deck }
```

with a 10 pt handle layout width.

1. **`NSSplitView` with `canCollapseSubview` was rejected, not merely skipped.**
   Each additional AppKit hosting pane re-derives the window's top safe area on
   its own schedule, which causes titlebar safe-area drift. That is the same
   failure mode recorded as rule 2 in
   [`flat-window-chrome-titlebar-merge.md`](flat-window-chrome-titlebar-merge.md):
   no fixed arrangement of per-pane safe-area escapes stays correct across
   launch, full-screen round trips, and refocus. A plain `HStack` plus one
   explicit width keeps the pane count unchanged.

2. **All resize decisions live in pure rules.** `WorkbenchSidebarResize` holds
   the arithmetic so it is testable without a window:
   - clamp the dragged width to the sidebar bounds 220 / 300 / 560 pt;
   - **collapse on release** below 180 pt, which is minimum − 40;
   - **reopen live** once a drag from the collapsed state passes +32 pt.
   Collapse is release-triggered and reopen is drag-live on purpose: a
   release-triggered reopen would feel dead, and a live collapse would flicker
   while crossing the threshold.

3. **Cursor push/pop must balance.** The handle pushes a resize cursor on hover
   and pops it on exit, and both calls are guarded so a pop can never run
   without a matching push. An unbalanced `NSCursor` stack leaves the resize
   cursor stuck over unrelated views for the rest of the session.

4. **The handle is not a window-drag surface.** `isMovable` is false and window
   movement is opt-in per surface; adding a `WindowDragHandle` here would make
   every resize also move the window.

5. **Visual width is narrower than hit width.** The grab bar is centred inside
   the 10 pt handle, so the pointer target is wider than the mark.

6. **Persistence is debounced and backward compatible.** `RestorableWorkspace`
   gained `sidebarWidth` and `isSidebarCollapsed`, both decoded with defaults
   (300 pt / false), so records written before this change still load. Writes
   are debounced 200 ms, because a drag emits a width per frame.

7. **Accessibility.** The handle has the help text "Drag to resize" and is a
   VoiceOver adjustable named "Sidebar width" that steps +/-20 pt. There is
   deliberately no double-click action, so there is no hidden-only path to a
   width.

8. **The minimum window width is derived, not chosen.** 40 (rail) + 220
   (sidebar minimum) + 10 (handle) + 472 (deck) + 16 (inset) = 758, and the
   window minimum is 770 pt (it moved 720 → 760 → 770 during this work).
   Recompute it whenever the rail width, sidebar minimum, or handle width
   changes. Note that Search and Source Control carry an inner `minWidth` of
   300 pt, so selecting those sections can push the sidebar wider than 220.

### 2026-10-20 update: no idle seam, and the minimum is 774 pt

- **The idle seam is removed.** The handle draws nothing at rest; the grab bar
  appears on hover only. A permanently visible 10 pt seam read as a third
  structural edge next to the rail and the deck.
- The window minimum moved 770 → **774 pt**:
  40 + 220 + 10 + 472 + 20 = 762 plus margin (the deck inset went 8 → 10 pt).
  The arithmetic rule above is unchanged — redo the sum on any width change.

Recorded in [ADR 0031](../decisions/0031-card-header-tabs-and-themed-chrome.md).

## Why it matters

The obvious implementation — an `NSSplitView` with a collapsible subview — is
the one that breaks the window chrome this app depends on, and it breaks it
intermittently across full-screen and focus events rather than immediately. The
custom handle trades that for arithmetic that unit tests can pin, at the cost of
owning the cursor stack and the clamp/collapse thresholds by hand.

## Reproduction or evidence

- The safe-area drift behind rule 1 is the TitleBarProto strategy comparison
  recorded in `flat-window-chrome-titlebar-merge.md` rule 2.
- Phase 3 of the window redesign, commit 450c453 on `main`.

## Verification

Gates on `main` 96e54b3: `./script/format.sh --lint` clean; `swift build` with
0 warnings; parallel suite 250 + 2651 tests passed; `./script/test.sh
--no-parallel` (CI mode) 250 + 2651 passed; `./script/build_and_run.sh
--verify` launched Rafu Lightning.

Still open by hand: drag to both bounds, release below 180 pt to collapse,
drag back past +32 pt to reopen, the cursor over the handle and after leaving
it, VoiceOver on the adjustable, the 770 pt minimum window, and a restart
keeping the stored sidebar width.

## Related code, ADRs, and phases

- [ADR 0030](../decisions/0030-framed-workbench-left-rail-and-detached-tabs.md),
  section c.
- [`flat-window-chrome-titlebar-merge.md`](flat-window-chrome-titlebar-merge.md),
  rule 2 and "One left Activity Rail".
- [`nssplitview-divider-position-quantization.md`](nssplitview-divider-position-quantization.md)
  for the remaining inner `NSSplitView` usages.
- [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md).
