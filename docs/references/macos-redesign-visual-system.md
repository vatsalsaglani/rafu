# macOS redesign visual system ("One Gold Thread")

- Applies to: the colour, focus, shadow, typography, motion, and haptics rules
  from the macOS redesign (`docs/plans/phases/macos-redesign.md`), as implemented
  in `Sources/RafuApp/Support/` and the workbench, Source Control, terminal,
  Ensemble, Settings, and Canvas views.
- Last verified on Mac: Apple Swift 6.4 (Swift 6.2 language mode), macOS
  27.0.1 (26A434), 2026-10-18. The app builds and the canonical Lightning
  launch check passes. See the phase plan for the scope of the UI checks.
  The earlier Linux syntax and scratch-test checks remain recorded there.

## Rule or observed behavior

### Gold budget

Gold (the `accent` and `focusRing` tokens) is a thread, not a fill. It appears
only for:

1. keyboard focus inside content (focus ring);
2. the current selection;
3. a live agent message link on the Canvas;
4. the one primary action in a view;
5. the focused terminal's border.

Everything else is neutral: `textSecondary` for glyphs and secondary controls,
`borderSubtle` for structure. Applied in shared styles:

- Active icon buttons use the selection fill, not gold.
- Sheet header icon, glyphs, the dirty dot, and the sparkline use
  `textSecondary`.
- Editor-group border is `borderSubtle`. With more than one editor group, the
  focused group gets a `borderStrong` hairline. Gold on an editor group appears
  only when it hosts the focused terminal
  (`TerminalSurfaceBorderStyle.Context.editorGroup(isFocused:hostsTerminal:hasSiblings:)`).
- Ensemble attention states use `warning`, not `accent`.
- Sync state (Source Control) is a neutral capsule.

### Focus language

Focus rings are drawn from the SwiftUI `\.isFocused` environment value with the
`focusRing` token. Rings mean keyboard focus only; hover and selection use
other treatments. Relationships between Canvas cards are dashed "stitches";
live message links are solid gold.

### Canvas-only shadows

Shadows exist only on Canvas cards: two layers using `Color.black` at low
opacity. There is no palette token for shadows, so this is the one place a
literal colour is used. Workbench chrome, sidebars, and sheets do not get
custom shadows.

### Typography roles

- SF Pro: UI chrome. Canvas note Edit mode also uses SF Pro.
- SF Mono: code and data.
- New York: Markdown and note prose, per the phase brief. See the open
  question at the end on whether every Markdown surface was switched.

### `RafuMotion`

Pointer-driven changes (drag, resize, pinch, scroll) and keyboard-driven
changes (typing, caret, focus rings, tab and list navigation) never animate.
Only discrete changes use `RafuMotion`. Values in `Support/RafuMotion.swift`:

| Group | Value |
|---|---|
| Hover in / out | ease-out 0.10 s / 0.16 s |
| Press release | ease-out 0.12 s |
| Selection | ease-out 0.08 s |
| Contextual hover hide delay | 0.30 s (prevents flicker) |
| Node create | spring, response 0.28, damping 0.9 |
| Node remove | ease-in 0.14 s |
| Lift / set down | ease-out 0.12 s / 0.16 s |
| Resize return | spring, response 0.25, damping 0.85 |
| Target highlight | ease-out 0.10 s |
| Connection cancel | ease-in 0.16 s |
| Edge draw-in | ease-out 0.24 s |
| State cross-fade | ease-in-out 0.16 s |
| Message travel | 0.5 s; more than 3 messages in 2 s show only a count |
| Note mode swap | ease-in-out 0.12 s |
| Zoom step / zoom to fit | ease-in-out 0.18 s / 0.26 s |
| Panel toggle | ease-in-out 0.20 s |
| Success hold | 1.2 s |
| Guide fade-out | ease-out 0.15 s |
| Reduced-motion replacement | ease-out 0.12 s fade |

`RafuMotion.resolve(_:reduceMotion:reduced:)` returns the animation, or the
`reduced` animation (default: none) when Reduce Motion is on. Travel, scale,
and spring motion get a fade or nothing under Reduce Motion; the link message
dot is replaced by a badge pulse.

### `RafuHaptics`

- One mechanism only: `NSHapticFeedbackManager.defaultPerformer` with
  `.alignment`, `performanceTime: .drawCompleted`.
- Used for a snap to a guide, a port, a minimum size, or the 100% zoom detent.
- Throttled to one per 100 ms per channel.
- User setting: `canvasHapticsEnabled`, default on (Settings, General).
- Never the only feedback: every call site must also show a visual cue.
- Never called for incoming agent messages, link state changes, or results.
- No success or failure haptics exist on the Mac (see facts below).

Apple documentation facts (read from Apple documentation JSON):

- `NSHapticFeedbackManager` works on Force Touch trackpads. Patterns:
  `generic`, `alignment`, `levelChange`. Performance times: `default`, `now`,
  `drawCompleted`.
- Apple says the feedback is "intended in response to a user action" and not
  to be used "for events that are not user initiated".
- SwiftUI `sensoryFeedback`: `.alignment` plays on iOS and macOS;
  `.levelChange` is macOS only; `.success`, `.error`, `.impact`, `.selection`
  are iOS and watchOS only.

## Why it matters

Gold carries meaning only if it is scarce. A neutral structure lets focus,
selection, and live links stand out without relying on colour alone. Pointer
and keyboard motion would add latency to frequent actions. Haptics that fire
on non-user events break Apple's guidance and cannot be felt on most Macs.

## Reproduction or evidence

- Read `Sources/RafuApp/Support/RafuMotion.swift` and `RafuHaptics.swift` for
  the exact values above.
- Apple facts: fetch
  `https://developer.apple.com/tutorials/data/documentation/appkit/nshapticfeedbackmanager.json`
  and the SwiftUI `sensoryfeedback` page (see
  [`linux-swift-verification.md`](linux-swift-verification.md)).
- Mac UI checks found that borderless native `Menu` controls use the inherited
  tint even when their label has a neutral `foregroundStyle`. Set a neutral
  `.tint` on secondary Git and Canvas menus. A label color alone does not
  enforce the gold budget.
- The native Agents table also adds column spacing to the declared widths.
  Keep the non-model columns bounded at the 680-point Settings window width.
  Use a shrinkable menu label and reserve the refresh button width; a menu
  Picker's intrinsic label can otherwise push the refresh control outside the
  table. Reproduce with a long custom model ID in Settings > Agents. Open the
  model menu and confirm the complete value is still available.
- Bound the board layer to the GeometryReader viewport before attaching the
  zoom overlay. A scaled card keeps its unscaled layout size in SwiftUI. Without
  the explicit frame, a large card can expand the ZStack and push the zoom
  controls beyond the right edge in a smaller window. Reproduce by opening a
  board with a large terminal card at 58% in an 1100-point window.
- Force Touch haptics have not been checked.

## Verification

Build and run `./script/build_and_run.sh --verify`, then run a
visual pass that checks gold appears only in the five places above, in Light
and Dark, with Increase Contrast and Reduce Motion on. Haptics need a Force
Touch trackpad.

## Related code, ADRs, and phases

- `Sources/RafuApp/Support/RafuMotion.swift`, `Support/RafuHaptics.swift`,
  `Support/RafuTheme.swift`, `Support/RafuWorkbenchStyles.swift`.
- Phase: [`../plans/phases/macos-redesign.md`](../plans/phases/macos-redesign.md);
  source spec `docs/plans/phases/macos-redesign/review.html` (sections 06, 07, 08).
- Related references: [`ui-design-language.md`](ui-design-language.md),
  [`canvas-interaction.md`](canvas-interaction.md).
- Markdown preview prose already used New York before the redesign: the theme
  JSON key `fonts.markdownPreview.prose` (Indigo and Khadi set `"New York"`,
  fallback Georgia). Canvas notes in Read mode use the same family through
  `RafuNoteMarkdownStyling.swift`; Edit mode uses SF Pro.
