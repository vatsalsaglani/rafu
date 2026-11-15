# Frosted window base: what works on macOS 27.2 and how to check it

- Applies to: the optional frosted window base
  (`Sources/RafuApp/Views/WindowFrostBackdrop.swift`,
  `Sources/RafuApp/Settings/WindowSurfacePreference.swift`,
  `rafuFrameSurface`, and the deck corner wedges in
  `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`)
- Last verified: Xcode with macOS 27.2 SDK (26B118), Swift 6 language mode,
  Darwin 27.2.0, Mac17,13, 2026-11-15. Merged to `main`; build OK; parallel
  and `--no-parallel` both green on `main`, each reported as 451 tests in 31
  suites plus 3708 tests in 301 suites (the two test targets). Rafu Lightning
  launched from `main` and the one-time migration set `windowSurfaceStyle =
  frosted`, `windowSurfaceFrost = balanced`. GUI checks of the final build are
  not done (see the phase work log). Steps 2 and 3 (commit de54821): Swift
  6.4.2, same Xcode/SDK; GUI check not done. Opaque board cards, the margin
  strip fix and the note editor fix (commit b97bbb7, merge adb61a9): macOS 27.2;
  Apple Swift 6.4.2 (swiftlang-6.4.2.1.9); the probes ran offscreen
  (`cacheDisplay`), not in Rafu Lightning; GUI check not done.

## Rule or observed behavior

1. **A behind-window `NSVisualEffectView` needs no `isOpaque = false`.** It
   blurs the real desktop with `NSWindow.backgroundColor` and `isOpaque`
   unchanged. Rafu uses `.behindWindow`, material `.hudWindow`, state `.active`.
2. **Use `.active`, not `followsWindowActiveState`.** The following state turns
   the frost flat grey on every focus change. `.active` keeps the frost when the
   window is inactive; the user approved that.
3. **Liquid Glass gives no desktop blur as a base.** On an opaque window,
   `NSGlassEffectView`, SwiftUI `glassEffect`, and
   `containerBackground(.ultraThinMaterial, for: .window)` show no desktop. On a
   clear window, `NSGlassEffectView` shows the desktop sharp and tinted, with
   no blur. Glass stays an option for small controls only.
4. **SwiftUI `Material` blurs only inside the window.** It cannot frost the
   desktop.
5. **`maskImage` is the reliable mask on a behind-window view.** Rafu uses it
   for the deck corners: four 2r x 2r tiles with an even-odd continuous-corner
   image. **Cache the image**, because `updateNSView` compares by identity.
6. **`screencapture -l<windowid>` does not show behind-window blur.** Use a
   region capture of the screen (`screencapture -R`) instead.
7. **The spike defaults are the source of "Balanced dark".** The user approved
   Indigo with tint 0.5; that is Balanced dark (0.50). Table and the rest of the
   decision: [ADR 0038](../decisions/0038-optional-frosted-window-base.md).
8. **Frame surfaces paint nothing in Frosted.** `rafuFrameSurface(.app /
   .sidebar / .statusBar)` paints its token only in Solid. A direct opaque fill
   on a frame surface leaves a solid patch in Frosted, and nested paints would
   stack. A theme's distinct `sidebarBackground` is not shown in Frosted.
9. **Terminal alpha (step 3, landed 2026-11-15, commit de54821).** SwiftTerm
   uses the CoreGraphics path with RGBA layer contents, so alpha works without
   patching it. Details are in "Terminal alpha" below.
10. **Deck, content and board paint once (steps 2 and 3).** In Frosted the deck
    card paints no base. Each region paints its colour once through
    `rafuDeckFill(color, layer)` or `windowSurface.fill`, so translucent fills
    never stack. Layer meanings, the opacity table and the deck shadow ring are in
    the ADR 0038 Amendment. Split gaps use `rafuFrameSurface(.app)`.
    **Ensemble cards are the exception:** they paint `DeckLayer.boardCard`, which
    is 1 in Frosted and in Solid (second Amendment; see rule 13).
11. **New contract.** Every full-region fill in the deck or on the board must use
    `rafuDeckFill` or `windowSurface.fill`, never a direct opaque
    `.background(palette...)`. A new node kind must not paint a second card-role
    fill. A card shell and a floating board control use the `.boardCard` layer; a
    card face resolves as Solid through
    `.environment(\.rafuWindowSurface, .solid)` in the shell, so a new node kind
    needs no frost code. `FrostedDeckContractTests` enforces the main call sites.
    (This rule is here and in ADR 0038 on purpose; it is not in AGENTS.md.)
12. **Popovers and sheets** inherit `rafuWindowSurface`. `RafuCardHeaderRow` uses
    the `pinned` layer, so a Markdown code-block header in a popover is very
    slightly translucent. Popovers opened from card content now resolve Solid.
13. **A translucent card always shows what is below it.** A single layer with
    alpha `a` shows `(1 - a)` of what is under it, so no alpha below 1 hides a
    lower card. The old `card` layer (about 0.67 over the board at Balanced dark)
    showed a lower card at about 33 %; with the terminal alpha 0.82 the lower
    card still showed at about 6 % (the user screenshot). Cards are therefore
    opaque and only the board is frosted. One behind-window
    `NSVisualEffectView` for each card was rejected: up to about 50 WindowServer
    blur regions moved on every pan and zoom frame. `.card` stays for the
    tab-shelf fade (`EditorCanvasView.fadeTone`) and `.pinned`.
14. **An `NSView` is not clipped to its bounds, and `draw(_:)` can get a
    `dirtyRect` larger than the bounds.** On this SDK a probe printed dirty
    `(0,0,600,310)` for bounds `(0,0,600,6)`. `dirtyRect.fill()` in
    `TerminalMarginFillView` therefore painted the translucent background over
    the whole terminal, above the text: probe text luminance 233 became 69 and
    the background alpha went from 0.82 to 0.97. This faded the text of every
    Frosted terminal (cards, tabs, Terminal Groups) when "Frost the editor and
    terminals" was On. Fix: fill `bounds.intersection(dirtyRect)` and set
    `clipsToBounds = true`. Regression test `terminalMarginFillStaysInBounds`
    (verified to fail on the old code). Do not use `dirtyRect.fill()` in a custom
    view that must stay inside its frame.
15. **A clip view with `drawsBackground = true` composites onto an opaque grey.**
    An `NSScrollView` / `NSClipView` with `drawsBackground = true` and a clear or
    translucent `backgroundColor` draws that colour over an opaque base of about
    `#1E1E1E`, not over transparency. Probe: clear colour gives opaque `#1E1E1E`;
    with `drawsBackground = false` the result is transparent. This made the note
    card edit mode grey in Frosted (screenshot). When the base is not opaque, set
    `drawsBackground = false` on the scroll view and the text view and write the
    colours only when opaque (`CanvasNoteEditor.updateNSView`).

## Terminal alpha

- Alpha goes in SwiftTerm `nativeBackgroundColor`. The layer background is
  cleared after font/`installColors`, and restored at alpha 1.
- Terminal alpha applies to terminal tabs and Terminal Group panes only. A
  terminal in an Ensemble card resolves Solid (alpha 1; rule 13), so SwiftTerm
  composites an opaque layer and the margin strip is not needed there. A terminal
  view that moves between a tab (alpha 0.82) and a card (alpha 1) restores its
  opaque layer colour through the `applyTheme` signature guard; not yet checked
  in the GUI with Transfer Here.
- Alpha is never 0. SwiftTerm draws inverse-video (SGR 7) text in that colour, so
  at alpha 0 the text would vanish. Contrast of inverse text still drops at
  Strong.
- SwiftTerm fills cells with `NSRect.fill()` (copy mode), so the alpha is exact.
  It leaves the strip below the last row unpainted, so Rafu adds
  `TerminalMarginFillView` (no clicks, hidden from accessibility). It must fill
  only `bounds.intersection(dirtyRect)` (rule 14).
- SwiftTerm `draw(_:)` is `public` but not `open`; Rafu cannot override it.

## TextKit editor alpha

- Keep `drawsBackground` on with a clear text view. Current-line highlight,
  indent guides and bracket borders draw in `drawBackground(in:)`.
- Put the base on the clip view. Otherwise a short text view leaves a gap below
  it.
- `NSRectFill` in copy mode makes the line highlight copy its translucent colour
  instead of blending; it then composites over the clip view.
- Views with translucent backgrounds must report `isOpaque` false.
- The gutter base and the legacy scroller track follow the editor alpha.
- Alpha is part of `EditorColorSet`, so AppKit writes happen only on change.
- Rule 15 applies: a clip view with `drawsBackground = true` and a translucent
  colour composites onto an opaque grey base. The note card editor is fixed. The
  main editor (`CodeEditorView.swift`, around lines 139 and 751) sets a 0.82
  alpha colour on its scroll view with `drawsBackground = true` and may have the
  same defect (an opaque editor with an 18 % grey mix). **Open: not verified on
  screen.** The live proof exists only for alpha 0. Check with a region capture
  (`screencapture -R`) before any change.
- Ensemble card faces do not use this path in Frosted: they resolve Solid.

## Why it matters

- Spike evidence decided the mechanism; without it a later change could swap
  in Liquid Glass or a Material and lose the desktop blur without any error.
- A screenshot with `-l` makes a working frost look broken, so a reviewer might
  report a false failure.
- Cost, from the spike (Debug build, busy Mac, rough): WindowServer CPU +4 to
  +5 points (17.3 to 22.6 % with a moving backdrop; 16.1 to 20.4 % static).
  Rafu memory changed by less than 1 MB. These are not Release numbers.
  **Re-measure in Release.**

## Reproduction or evidence

The spike (debug default `RafuFrostSpike`; keys migrated and deleted by
`RafuApplication.init()`) produced screenshots in a temporary scratchpad folder
that may be gone. The findings above are the durable record.

## Verification

Manual, Rafu Lightning only (never the release `Rafu` process):

1. `./script/build_and_run.sh --verify`.
2. Settings > Appearance > Window: switch "Window background" between Solid and
   Frosted; step Frost through Subtle, Balanced, Strong, in Indigo and Khadi.
   Frost is disabled when Solid.
3. System Settings > Accessibility > Display: turn on Reduce Transparency, then
   Increase Contrast. The window must go Solid at once and the setting shows
   the footer that explains why.
4. Open a second window; it must follow the setting.
5. Capture with a region (`screencapture -R`), never `-l`.
6. Footprint of `pgrep -x RafuLightning`, and WindowServer CPU with Solid and
   with Frosted in the same scene, in a Release build. The exact commands the
   spike used were not recorded in the handoff; record them here when the
   Release measurement is made. For steps 2 and 3 also measure, in Solid and in
   Frosted: typing p95, a terminal flood (`yes | head -200000`), and a 40-card
   board pan. New Frosted-only costs: one mask pass for the deck shadow, and
   SwiftTerm compositing a non-opaque layer in terminal tabs and groups. (The
   per-card shadow mask pass and the card-terminal non-opaque layer were removed
   by the opaque card change.) No numbers exist yet.
7. Steps 2 and 3 GUI checks owed (none done): Indigo and Khadi, each at Subtle,
   Balanced and Strong, with "Frost the editor and terminals" On and Off; the tab
   shelf fade at the trailing end; inner split corners (editor-group corner
   wedges paint `appBackground` at the tint opacity, so a small mismatch is
   expected there); the terminal bottom strip; card edges; the shadow ring edge;
   text antialiasing over clear text views; inverse (SGR 7) terminal text.
8. Opaque board cards GUI checks owed (none done; capture with `screencapture
   -R`): Indigo and Khadi, Subtle, Balanced, Strong, switch On and Off. (a) Two
   overlapping terminal cards: nothing of the lower card shows and text is as
   bright as in Solid. (b) A terminal tab and a Terminal Group pane: bright text,
   no gap in the bottom strip. (c) A note card: edit and read mode have the same
   tone, no grey, no strip on the left edge (the left strip is unexplained by the
   code). (d) File, view, Mermaid, image and web app cards look as in Solid. (e) A
   floating control over a card: the card does not show through. (f) A narrow
   note card in edit mode: "Return to Board" is on one line or shows only the
   key hint. (g) Solid, Reduce Transparency and Increase Contrast unchanged; a
   second window follows the setting. (h) Pan a 40-card board in Frosted. (i)
   Transfer Here of a terminal between a tab and a card.

Automated: the pure resolver `WindowSurfacePreference` is covered by the
`main` gates above; the test names were not supplied. Steps 2 and 3 add
`FrostedDeckContractTests`, which enforces the main `rafuDeckFill` /
`windowSurface.fill` call sites. Test counts for the steps 2 and 3 merge are in
the phase work log. The opaque card change adds the regression test
`terminalMarginFillStaysInBounds` in `FrostedDeckTests` (fails on the old
`dirtyRect.fill()`; verified) and contract scans in `FrostedDeckContractTests`
for `.boardCard`, `.environment(\.rafuWindowSurface, .solid)`, the two
`drawsBackground` writes in `CanvasNoteEditor.swift`, `ViewThatFits` and
`.lineLimit(1)` in `CanvasCardChrome.swift`, and no `dirtyRect.fill()` in
`RafuTerminalView.swift`.

## Related code, ADRs, and phases

- [ADR 0038](../decisions/0038-optional-frosted-window-base.md); amends ADRs
  0012, 0022, 0030, 0031
- [`workbench-deck-corner-wedges.md`](workbench-deck-corner-wedges.md)
- [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
- [`sidebar-panel-anatomy-and-terminal-rows.md`](sidebar-panel-anatomy-and-terminal-rows.md)
