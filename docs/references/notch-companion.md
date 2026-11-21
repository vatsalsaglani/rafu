# Notch companion: geometry, click-through, focus non-theft, usage-file shapes

- Applies to: `Sources/RafuApp/Notch/**` (resting strip, peek panel,
  `NotchCompanionModel`, `AgentUsageProvider`/`CodexUsageProvider`/
  `ClaudeUsageProvider`), and the ADR 0016 attention-surface arbitration
- Last verified: Swift 6.2, macOS 26, 2026-07-22 (real on-notch-hardware
  GUI verification); rule 11 added 2026-07-26

## Rule or observed behavior

**1. Notch geometry has no public API — it is derived, not queried.**
There is no `NSScreen`/`AppKit` API that returns "the notch rect."
Geometry is derived from `NSScreen.safeAreaInsets.top` (the band height)
and the horizontal gap between `NSScreen.auxiliaryTopLeftArea` and
`auxiliaryTopRightArea` (the notch width sits between them). If either
auxiliary area is `nil`, there is no notch, and the companion turns
itself off entirely (`Show notch companion` has no visible effect on
non-notch displays — no second preference, no manual override). Update
2026-11-15: a Mac with a hole-punch camera and system Dynamic Island returns a
59 x 40 housing from the same derivation, so `NotchHUDGeometry.cutout(for:)`
now classifies `none`/`notch`/`islandCamera` and `notchRect` returns a rect only
for a real notch. On an island Mac the companion is a Usage-only pill below the
menu bar or a menu-bar status item, never a surface in the menu-bar band around
the island; see [`dynamic-island-macs.md`](dynamic-island-macs.md) and
ADR 0037. Probed on
this machine: screen 1710×1107, `safeAreaInsets.top` = 33, aux-left
`(0, 1074, 763, 33)`, aux-right `(948, 1074, 762, 33)`, giving a notch
`x ∈ [763, 948]`, width 185.

**2. Click-through must be verified at the AppKit hit-test layer, not
via `.allowsHitTesting`.** SwiftUI's `.allowsHitTesting(false)` is
insufficient by itself for a panel that must let clicks fall through to
the real menu bar underneath. The working pattern is a passthrough
hosting `NSView` overriding `hitTest(_:)`: convert the point to SCREEN
coordinates with `window.convertPoint(toScreen:)`, and return `nil`
(letting the click fall through to whatever is behind the panel) when the
point lies inside a click-through region; otherwise defer to
`super.hitTest`. This was verified by dispatching real `CGEvent` clicks
against a live menu, not by inspecting view hierarchy state. The shipped
v1 drop-down reuses the same view class with empty click-through regions
— behavior for the existing drop-down is unchanged.

**3. Focus non-theft is a single-flag, single-call-site invariant.** The
companion panel is an `NSPanel` configured `.nonactivatingPanel`.
`canBecomeKey` returns true ONLY when a separate `allowsKeyStatus` flag is
set, and that flag is set true in exactly one place: when the attention
feed's inline reply field engages. Wing clicks (open/pin the peek panel)
never touch `allowsKeyStatus` and never call `makeKey()`. `makeKey()`
itself appears exactly once in the codebase, inside `engageReply()`. This
single-call-site property is what makes "clicking a wing doesn't steal
focus from whatever app you were using" a structural guarantee rather
than a per-code-path habit — grep for `makeKey()` to re-verify after any
change.

**4. The companion panel is recreated (not reused) on screen-parameter
changes,** unlike the v1 event drop-down panel which persists for the
app's lifetime. Because of this, the companion panel's
`panelDidResignKey`/notification observers are attached and torn down
per-panel-instance. This is a leak trap the drop-down does not have: any
new observer registration on the companion panel must have a matching
teardown in its deinit/dismiss path, or repeated screen reconfiguration
(display sleep/wake, resolution change, external monitor plug/unplug)
leaks observers.

**5. Codex and Claude usage-file shapes (observed, will drift — these are
other tools' internals, not a contract Rafu controls):**

- Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, one JSON object
  per line: `{ "timestamp": ..., "type": "event_msg", "payload": { "rate_limits": { "primary": { "used_percent": ..., "window_minutes": ..., "resets_at": ... }, "secondary": { ... } } } }`. Rafu reads only the newest rollout file's latest snapshot.
- Claude Code: `~/.claude/projects/<slug>/<uuid>.jsonl`, one JSON object
  per line with `"timestamp"` (ISO 8601, fractional seconds, `Z`-suffixed)
  and `"message": { "usage": { "input_tokens": ..., "cache_creation_input_tokens": ..., "cache_read_input_tokens": ..., "output_tokens": ... } }`. Claude exposes no rate-limit percentage anywhere in this
  shape, which is why the Claude usage tile shows token totals for 5h/7d
  windows and never fabricates a percentage. Exact percentage rings need
  Connect; the card now says "Estimated from local transcripts" and offers
  "Connect for exact usage…". See
  [`usage-rings-and-pace.md`](usage-rings-and-pace.md) for the rings, pace,
  and the reasons Claude showed no ring.
- Both parsers treat every field as optional/version-tolerant; a missing
  or malformed file hides that tile rather than crashing or guessing.
  Reads are bounded (newest Codex rollout only, tail-read capped 256KB;
  newest 30 Claude transcripts within a 7-day window, each tail-read
  capped 256KB), run off the main actor, and refresh on a 60s TTL. Nothing
  parsed is prompt/response content — counts, percentages, and timestamps
  only — and nothing is logged, cached to disk, or transmitted. See ADR
  0016's 2026-07-22 amendment for the durable-decision framing of this
  capability.

**6. The attention feed's population is coupled to the existing `.hud`
attention-surface preference, not a bug.** A user who has the notch
companion enabled but has set the terminal attention-surface preference
to notification-only or none will still see the resting strip's wing dot
and per-editor attention chip counts (those are driven by session state
directly), but the peek panel's attention feed itself never populates
with cards. This is intentional: the feed and the v1 drop-down are two
presentations of one notch attention surface (see ADR 0016 amendment),
not independent toggles.

**7. VoiceOver discoverability is honest, not yet fully verified.** A
non-activating panel that never joins the Window menu may not be
independently discoverable by VoiceOver while it is merely resting or
peeking (as opposed to when the reply field is engaged and the panel
becomes key). The accessible fallback path remains the standard Terminals
panel, Source Control panel, and the v1 attention drop-down, all of which
are ordinary key-able surfaces. This has NOT yet been empirically tested
with real VoiceOver — track as an open verification item, not a resolved
claim.

**8. Two independently focusable fields on one non-activating panel need a
single OR-of-reasons key-status arbiter, not per-field flag-flipping.** NC-B
added a pinned editors-search field alongside the existing feed reply
field, so the panel now has two SwiftUI controls that each need
`allowsKeyStatus`/`makeKey()` while focused. If each field's own
`.onChange(of: isFocused)` set `allowsKeyStatus` directly, an AppKit focus
hop from one field to the other can transiently report BOTH as unfocused
mid-transition, and the outgoing field's disengage would drop key status
out from under the incoming field. The shipped fix in
`NotchCompanionModel`: each field only toggles its OWN boolean engagement
flag (`isReplyEngaged`/`isSearchEngaged`, both `private(set)`); a single
`updateKeyStatus()` arbiter derives `panel.allowsKeyStatus = isReplyEngaged
|| isSearchEngaged` and calls `makeKey()` only on a false→true edge (this
supersedes rule 3's older claim that `makeKey()` has exactly one call
site — it is now the panel's sole `allowsKeyStatus` write location that
matters, guarded per-field). A separate `clearKeyEngagement()`
unconditionally zeroes BOTH flags and sets `allowsKeyStatus = false`
without going through the arbiter, for genuine window-level key loss
(`panelDidResignKey`, `teardown`) — using `updateKeyStatus()` there instead
would incorrectly leave `allowsKeyStatus` true if the other field still
thought it was engaged. This generalizes: any borderless/non-activating
panel hosting more than one focusable control must arbitrate key status
through one OR-of-reasons function, never per-control.

**9. The peek panel's editors-search field is threshold-gated, pinned
above the internal scroll, and its query is ephemeral.** The field
(`CompanionSearchFieldView`) appears once `editorRows.count >=
searchFieldThreshold` (6) OR the trimmed query is already non-empty (so
narrowing the list below 6 via typing does not also make the field
disappear out from under the user). It sits directly under
`CompanionWingsView` and above the internal `ScrollView` that hosts the
usage strip, editors list, and attention feed, so it stays reachable while
results below it scroll. Filtering (`CompanionEditorRow.filteredEditorRows`)
narrows only the editors list — the usage strip and attention feed are
never filtered — via a plain, un-tokenized, case- and
diacritic-insensitive substring match against `name` OR the raw `branch`
field (kept separate from the decorated `gitSummary` one-liner, which is
lossy for detached-HEAD/unborn-branch states). `searchQuery` is cleared on
every collapse back to `.resting` — it is not persisted and does not
survive a hide/show cycle.

**10. Front-line usage rendering: per-row Grid layout with contextual
window capping.** The peek panel's front-line usage area (up to 4
user-ordered providers) renders as a SwiftUI `Grid`/`GridRow`, one provider
per row, with aligned name and windows columns, monospaced 10.5pt.
Each row has `.lineLimit(1)` and its own accessibility label. Window capping
is contextual: `UsageDisplayPolicy.tileWindowCap = 2`, but
`frontLineWindowCap(providerCount:)` returns `nil` (uncapped) when a sole
provider occupies the front line, allowing per-model detail to show (e.g.
Claude's `Fable 7d 48%`); for 2+ front-line providers, it returns `2`,
truncating to first 2 windows per tile. Overflow grid tiles (behind the
disclosure line) always cap at 2 windows. Emphasis (≥80% accent-semibold,
≥95% ⚠ glyph) applies to surviving windows. Height layout uses
`usageFrontLineRowHeight = 16` per row + one-time `usageFrontLineTopPadding`
(RafuMetrics.space2), replacing the prior single-row `usageFrontLineHeight`.
`peekContentHeight()` widened from `private` to internal visibility for test
assertion of per-row growth (matches other internal pure derivations like
`usageFrontLine`).

**11. On a multi-display setup the notch surfaces belong to the NOTCHED
screen, not the active one.** `NotchScreenAdapter.currentMetrics()`
originally resolved one screen as `NSApp.keyWindow?.screen ?? NSScreen.main
?? NSScreen.screens.first`. In extended-desktop use that is the external
monitor whenever the user is working there, which silently disabled both
notch surfaces on the built-in display: the v1 drop-down fell back to the
external's top-center non-notch layout, and the companion strip vanished
outright, because `NotchCompanionGeometry.restingStripFrame` returns `nil`
without a notch and `activateIfEnabled()` tears the panel down on `nil`.
Symptom from the user's chair: "the notch is empty until I drag the Rafu
window back onto the laptop." The adapter now collects candidates in
preference order (key-window screen, `NSScreen.main`, then all screens) and
runs them through the pure `NotchScreenSelection.preferred(from:)`, which
returns the first candidate with a derivable notch rect and only falls back
to `candidates.first` when NO attached screen has one (clamshell, desktop
Mac, external-only) — preserving the follow-the-active-window behavior for
the non-notch fallback layout. General rule: a surface that exists to
occupy fixed physical hardware must be anchored to the display owning that
hardware, never to whichever display currently has focus.

**12. The resting notch strip is the left wing plus the housing, at `.statusBar`
(rewritten 2026-11-17 (2)).** MenuBarAgent draws status items, including the "«"
overflow, in a window at layer 25 (`.statusBar`), above the layer-24 menu bar. On
a notched Mac on macOS 27 the "«" chevron sits immediately right of the notch.
History: the 2026-11-15 rule lowered the strip to `mainMenu - 1` (23) on macOS 27;
a level-23 window gets no tracking-area hover, so a pointer watch was added
(2026-11-17); device photos then showed that Reduce Transparency makes the opaque
menu bar hide a level-23 window completely. Both are removed
(`CompanionPanelLayering`, `CompanionPointerWatch`). Rule now:

- The resting notch frame is x = `notch.minX - restingLeadingWingWidth`, width =
  `notch.width + restingLeadingWingWidth`, top-pinned, notch height. The right edge
  is `notch.maxX`: nothing sits right of the notch. `restingLeadingWingWidth` = 84,
  `housingHiddenInset` = 16, so about 68 pt shows. On the reference metrics
  (notch 763 to 948) the frame is (679, 1074, 269, 33).
- Mascot and one status item (attention, else agents, else editors:
  `CompanionRestingStatus`) share one row in the leading wing. One layout on every
  macOS version; no OS gate.
- The strip stays at `.statusBar` on every macOS version. Hover is `.onHover`
  again. `NotchHUDPanel.constrainFrameRect(_:to:)` stays: it returns the frame
  unchanged, because AppKit moves a window below level 24 out of the menu-bar band.
- Attention does not widen the notch strip (`isStripExpanded` is true for
  attention only on the pill); the glow still shows. The hover-expanded strip
  (90 + 90 pt) and the open panel are unchanged.
- Test seams (no fixed sleeps): `isHoverDwellPendingForTesting`,
  `isHoverGracePendingForTesting`, `fireHoverDwellForTesting()`.
- Rejected: keep the lowering (invisible with Reduce Transparency); level 24 (not
  proven); symmetric wings (cover "«"); widening for attention.

Not device-verified: whether the open "«" overflow draws left of the notch under
the left wing (FocusIsland PR 14 suggests yes), the 68 pt wing against long app
menus, hover after status items change, clipping of mascot plus a 2-digit count
with Reduce Transparency on and off, and macOS 26. Measured layers and facts:
[`dynamic-island-macs.md`](dynamic-island-macs.md) items 9 and 15; decision: ADR
0037 (amendment 2026-11-17 (2)).

## Cider-style rebuild (2026-10-18; updates stale text above)

Last verified: Swift 6.2 Linux read-through, 2026-10-18; not yet run on macOS.
Rules 1 to 11 above were verified on the earlier strip and peek design. Treat
statements about the resting strip, wings, and the editors-search field as
possibly stale until a macOS pass; geometry and focus rules were not re-checked.

What the code now has:

- Mascot: `Sources/RafuApp/Notch/NotchMascotView.swift`,
  `NotchMascotState.swift`, `NotchMascotGeometry.swift`.
- Sections in `Sources/RafuApp/Views/NotchSectionViews.swift`: Ensembles
  (open windows, their Ensembles, and agents, including agents outside any
  Ensemble), Up next, Now Playing, Usage (compact meters from the existing usage
  stores).
- Hover opens the panel (`NotchDisplayPreferences`: "Hovering the notch opens
  the panel", with a setting).
- Now Playing: the bundled MediaRemote adapter is the first source when enabled
  in Settings; Music and Spotify through public API are the fallback when it is
  off, missing, or stops. See
  [`agent-hooks-and-now-playing.md`](agent-hooks-and-now-playing.md).
- Agent state comes from hooks via
  `Sources/RafuApp/AgentTracking/AgentActivityStore.swift`; the notch,
  titlebar, and Ensemble terminal nodes each keep an output-based fallback when
  no hook session matches.

Not verified: which older strip, wing, and peek types still exist.

### Mascot: the thread sprite (2026-10-18)

Last verified: Swift 6.2 Linux syntax, format and stub type checks, and
cairosvg renders of the SVGs, 2026-10-18. Not yet built or seen on macOS.

The yarn ball with a needle is replaced by a thread sprite: a small, round,
soft body whose outline is one gold thread (a rim stroke and a stitched seam
inside it), a thin antenna that ends in a thread loop like the eye of a
needle, big dark glossy eyes with white catch-lights, a small smile, blush and
two tiny feet.

- Design source: `Resources/Mascot/rafu-{idle,working,needs-you,reply-ready}{,-still}.svg`,
  512 × 512. The animated variants use CSS keyframes and stop under
  `prefers-reduced-motion`; with no animation they show the still pose. The
  still variants contain no `@keyframes` (a test checks this). Colours are CSS
  variables (`--rafu-body-light`, `--rafu-body`, `--rafu-body-shade`,
  `--rafu-rim`, `--rafu-thread`, `--rafu-blush`) with Indigo defaults.
- Native rendering: `NotchMascotGeometry.swift` holds every path in the same
  512-point space; `NotchMascotView.swift` draws it. Keep the numbers in step.
  A test checks the shared silhouette start, the 512 view box and the loop
  pivot in the animated SVGs.
- Theme: the body gradient is the theme accent (lifted toward white in light
  themes, because the notch is always black and light-theme accents are made
  for paper). The rim, antenna, trail and sparkles are lighter accent tones,
  and the blush mixes the accent with the `error` token. Only the eye and
  mouth ink and the catch-lights are fixed colours. Increase Contrast replaces
  the soft rim with a solid outline in the light end of the theme.
- States (still pose / motion): idle — smile / slow breathing (about 1.5 %),
  antenna sway, a blink every other breath, a glance now and then. Working —
  eyes lower and look at the work, antenna leans −6° / antenna bobs, a short
  thread trail circles the loop. Needs you — wide eyes, small open mouth, a
  bead fills the loop / a small hop and a bead pulse every 2.8 s. Reply ready
  — `^ ^` eyes, open smile, two sparkles at the loop / one bounce per reply
  (`MascotBounceLedger`), then a sparse twinkle.
- Motion is one `.task` per mood of explicit `withAnimation` steps and
  `Task.sleep`; no timer. Hiding the view, a mood change or Reduce Motion
  cancels it, and the view returns to the still pose.
- Preview the SVGs without a browser: `cairosvg` does not resolve CSS `var()`,
  so replace each `var(--name, #hex)` with its fallback before you render.

## Companion chrome: glow border, open outline, tabs, cards (2026-11-15)

Last verified: Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0,
Mac17,13. Build and the branch parallel suite passed (3747 tests in 301 suites,
plus 466 in 33). Main gate: run by the coordinator. NOT checked on a device; the
owed checks are in the last list below. Decision: the visuals amendment of
[ADR 0037](../decisions/0037-dynamic-island-macs.md). Prior art: the user's own
Cider repo (read only): `Features/Notch/NotchHUDView.swift:77-81` (border),
`NotchOutline.swift:5-27` (shoulders), `CiderPillPicker.swift:21-59` (tabs),
`AgentsView.swift:68-129` (cards).

**13. What Cider's "animating gradient border" is.** It is a static
`LinearGradient` stroke (orange, pink, faded orange; 1 pt, 2 pt on peek) drawn
only while the panel is open or peeking. The animation the user saw is the SHAPE
changing as the panel opens. Rafu copies that and adds a sweep only on events
(rule 15).

**14. Open outline: one path fills, clips and strokes.** `CompanionOutline`
(from Cider `NotchOutline`):

- Top edge flush with the screen top; concave shoulders of radius
  `min(12, h/3)`; bottom radius `min(22, h/2)`.
- It animates from the closed strip, which has no shoulders and radius 12.
- The border path has no top edge. It is stroked at 2x width and clipped to the
  outline, so the visible line sits inside the shape.
- Shoulders exist only on the open notch/pill panel and on the drop-down under a
  notch. `peekPanelFrame` is 440 + 2 x 12 = 464 pt wide; the open frame on a
  notched screen is x 623.5, width 464. `NotchHUDController.panelWidth` gives the
  drop-down width. Content is inset by one shoulder on each side, so the content
  width is unchanged.
- No shoulders on the resting strip: they would change the hit area that the
  macOS 27 overflow layering depends on (rule 12).
- Hit testing uses the same path: `NotchHUDPanel.hitOutline` feeds
  `NotchHUDPassthroughHostingView.hitTest`. A `nil` result also stops hover, so a
  click beside a shoulder passes through to the menu bar (rule 2 pattern). Not
  device-verified.

**15. Border policy: `companionGlowBorder` and `CompanionGlowPolicy.resolve(...)`.**
The pure policy decides shown, width and motion; the modifier only draws.

| Surface | Border shown |
|---|---|
| Notch panel | Open, and on the widened strip while attention waits (Cider "peek") |
| Island card | Open (shape unchanged; the open card now has the border) |
| Attention drop-down | While an event shows |
| Menu bar card | Always while shown. Since Phase B (rule 18) it is the open-top stroke of `CompanionOutline` `.open` on `CompanionMenuPanel`; the earlier inset 2, radius 12 border inside the `NSPopover` is gone |

- Colours come from tokens: warning at low opacity, warning, accent at 0.65,
  warning at low opacity. 1 pt wide; 2 pt during a sweep.
- Product decision 6: the session colour stays the drop-down border; the
  gradient draws only when there is no session colour.
- Motion and energy rule: a 2.4 s sweep when the attention count rises (the
  drop-down: when a new event shows). A slow sweep (8 s per turn) only while the
  surface is open AND an agent works. Otherwise the border is still.
  `TimelineView` has a 30 fps cap and is paused when the border is still. One task
  wakes at the end of a sweep; there is no per-second timer.
- Reduce Motion, hidden or locked (through `rafuMotionScope`): still. Increase
  Contrast: one solid `borderStrong` line. Reduce Transparency: no low-opacity
  colours.
- `.rafuMotionScope()` is on the `NotchHUDView` root, because the drop-down
  belongs to no scene and would otherwise never see the motion scope.

**16. Tabs and spacing.** Tokens live in `CompanionChromeMetrics`:

| Token | Value |
|---|---|
| Pill track padding / spacing | 3 pt / 2 pt |
| Tab height | 28 pt (notch), 32 pt (menu card) |
| Tab inner padding | 10 pt |
| Tab text | 12 pt, semibold when selected |
| Selected fill | white 0.14 (Reduce Transparency: selection colour) |
| Track fill | white 0.065 (Reduce Transparency: `elevatedBackground`) |
| Pressed fill | accent 0.1 |
| Increase Contrast | outline on the selected tab |
| Pin and close buttons | 28 pt, 12 pt gap |
| Section side padding / gap between blocks | 16 pt / 10 pt |

- Tabs have equal widths up to 3 tabs. With 4 tabs, "Now Playing" with its icon
  and count was cut off at 440 pt. Equal widths are a 3-tab limit; do not add a
  fourth tab without a new width rule.

**17. Agent cards (`CompanionAgentCardView`).** Used for agents outside Rafu in
Other agents and Up next. Content: icon, a 2-line title, provider on the right,
the folder with `~`, an 8-character session suffix only when title and provider
collide, a state symbol and word, "Last seen Xm ago", the last message (2 lines)
and the sub-agents chip. Padding 10, radius 14, fill white 0.04. A card has no
action. "Last seen" comes from the `AgentActivityStore` clock, not from
`Text(style: .relative)`, which would keep work running while the panel is
hidden. The last message is the hook preview (see
[`agent-hooks-and-now-playing.md`](agent-hooks-and-now-playing.md)).

Not done: the plan's 32 pt "Open Rafu" footer, and a short commit sha (no sha
exists for an agent outside Rafu).

**18. Menu bar card as a custom panel (Phase B, 2026-11-15, commit 4eee050).**
Last verified: Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0,
Mac17,13. On `main` after menu step 4, D1 and the polling helper, both test modes
passed: 495 tests in 36 suites and 3870 tests in 314 suites (parallel and
`--no-parallel`). NOT checked on a device. Decision: the "Phase B custom panel"
amendment of [ADR 0037](../decisions/0037-dynamic-island-macs.md). The card is
`CompanionMenuPanel` (`Sources/RafuApp/Notch/CompanionMenuPanel.swift`), not an
`NSPopover`.

- **Shape.** `CompanionOutline` `.open` (12 pt shoulders, 22 pt bottom radius):
  one path fills, clips, strokes (`companionGlowBorder` open-top stroke) and
  hit-tests (`NotchHUDPassthroughHostingView.hitOutline`). Size 404 x 460 pt (380
  content plus 2 x 12 shoulders). Tokens `popoverBorderInset` and
  `popoverBorderRadius` are removed.
- **Placement (pure `CompanionMenuPanelGeometry`).**
  - Screen: the one holding the centre of the status item window, else the most
    overlap.
  - Top edge: `min(statusItemWindow.minY, visibleFrame.maxY)`. The bar is 45 pt
    on the island Mac, 37 pt on a notched Mac, 24 pt on an external display. With
    an auto-hidden or full-screen bar it is the bottom of the shown item.
  - Centred under the item; the body keeps 8 pt from the visible sides; never
    past the screen frame. A short screen gives a shorter card and the sections
    scroll. A display change moves the card under the item and does not close it.
- **Morph.** `CompanionMenuRevealShape` grows from a 36 pt nub with a 0.14 s fade
  both ways. Reduce Motion: a 0.12 s fade only.
- **Key focus.** `canBecomeKey` is true, `becomesKeyOnlyIfNeeded` is false, the
  panel calls `makeKeyAndOrderFront`, and nothing calls `NSApp.activate`, so the
  Dock and activation are unchanged. Level `.popUpMenu`; behaviours
  `[.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]`.
- **Close policy (pure `CompanionMenuPanelClosePolicy`).** A click in another app
  (global monitor: left, right, other mouse-down); a click in another Rafu window
  (local monitor; it ignores the status item's own window so its toggle does not
  close and reopen the card); Escape; the close button; a second status item
  click; loss of key; a Space change; `com.apple.screenIsLocked`;
  `sessionDidResignActive`; status item removal.
- **One close path.** Every close goes through `closeCard`, which calls
  `model.menuPopoverDidClose()` at once. ADR 0016 holds: feed cards drop at the
  start of the close, not after the fade. Each open builds a new panel. The model
  API keeps the "popover" names (`isMenuPopoverShown`, `menuPopoverWillShow`,
  `menuPopoverDidClose`) for parity.
- **Accessibility.** Window title "Rafu", subrole `.dialog`, label "Rafu". On
  close with VoiceOver, a `.layoutChanged` notification with the status item
  button returns focus.
- **No hidden default flag.** The user approved the change directly.
- **Testing nuance.** In `RafuAppTests`, `#expect(cgFloat == 982 - 37)` failed
  although both sides printed 945: the literal arithmetic inferred a non-CGFloat
  type. Write `CGFloat(...)` around the literal arithmetic. Tests:
  `CompanionMenuPanelTests` (12).

Owed device checks (not verified): typing a reply and Command-1 to Command-3
while another app is frontmost; whether the status bar window takes key on click
(the lost-key rule could then close and reopen the card); the top-edge shadow
during the morph; the VoiceOver dialog and focus return; an auto-hidden bar (the
card stays until a click outside); `.moveToActiveSpace` with
`.fullScreenAuxiliary` behaviour.

Owed device checks (not verified):

- Shoulders on a notched Mac, including the 464 pt open frame.
- (Closed by Phase B, rule 18: the popover border inset no longer exists.)
- Instruments energy while the border sweeps: the budget is under 2 % CPU. If it
  is over, the fallback is "sweep only on events" (drop the slow working sweep).
- Click pass-through beside the shoulders.
- Mismatch between the content inset (SwiftUI) and the AppKit panel frame
  animation while the panel opens.

**19. Approval rows (2026-11-20).** Last verified: the coordinator reported both
test modes passing on `main` (4040 and 634 tests); toolchain and OS version not
stated in the handoff. NOT checked in the GUI. Decision:
[`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md).
Code: `CompanionRequestView.swift`, `CompanionRequestPresentation.swift`,
`CompanionUpNextSectionView` in `NotchSectionViews.swift`,
`ApprovalClickGuard` and `ApprovalKeyEngagement` in
`CompanionApprovalGuards.swift`, `NotchCompanionModel.setApprovalRowsVisible(_:)`
and `noteApprovalInteraction()`. Tests:
`Tests/RafuAppTests/CompanionApprovalGuardsTests.swift`. The request source is
`AgentRequestStore.shared` (see
[`codex-app-server-approvals.md`](codex-app-server-approvals.md) and
[`claude-permission-request-hook.md`](claude-permission-request-hook.md)).

- **Badge.** While any request is pending, a "Needs approval" label (symbol
  `exclamationmark.bubble`, help text and VoiceOver text "Needs approval") takes
  the place of the attention dot in the resting status and of the usage glance
  in the island lobe. The island lobe accessibility label becomes "Rafu, Needs
  approval". The panel summary label adds "Needs approval".
- **Row.** Up next lists one request row per terminal row that has a window and
  a current request (the oldest request of that terminal). A row has the
  terminal title (opens the agent in its window), the title ("Run command",
  "Apply file changes", "Grant permissions", "Answer questions"), the command,
  the folder, the reason, the buttons the request permits, and always "Open
  terminal". The command always shows whole (no line limit, no "Show all"): a
  hidden tail must never run behind an active Run button. The command is at
  most 2 KiB, and a command with more than 2 blank lines or more than 64 spaces
  in a row is terminal-only, so the whole text fits the scrolling section. A
  `terminalOnly` request shows only "Open terminal". Every file change is
  terminal-only (the row cannot show the change). While an answer waits for the supervisor the row shows
  "Sending answer…". Rows with a request leave the normal feed and waiting
  lists.
- **Island card.** While a request is pending, the island card shows a "Close"
  button and the Up next section (request rows only, no feed and no waiting
  rows) instead of the saved section. When the last request closes, the card
  shows the saved section again; the saved selection never changed. On the
  notch panel, a click that pins the panel selects Up next when a request is
  pending and Up next is offered.
- **Key status only after an interaction.** A request that arrives must not
  take typing away from a terminal, even on a pinned panel.
  `ApprovalKeyEngagement.wantsKey` is true only when request rows are visible
  on a `.pinned` panel (`setApprovalRowsVisible(_:)`, not on the menu bar card,
  which is its own key panel) AND the person interacted with a request row: a
  click in it (a simultaneous tap gesture) or pointer movement over it
  (`onContinuousHover`), through `noteApprovalInteraction()`. The keyboard paths
  that already make the panel key (the reply and search fields) are unchanged. `updateKeyStatus()` combines the flag with the reply and
  search flags. An approval row never makes a resting or peek panel key.
  `clearKeyEngagement()` (lost key, teardown) ends the interaction; rows that
  leave the panel (or an unpinned panel) end it too, so the next request again
  needs an interaction.
- **Click guard.** After the list of request rows changes (a request closes, a
  new one appears or moves into place), `ApprovalClickGuard` ignores clicks on
  the answer buttons (Run, Deny, Answer and the others) for 0.5 s, so the second
  click of a double-click cannot answer the next request. The guard compares the
  request keys in display order and takes an injected clock. Choosing a question
  choice is not guarded (it sends nothing).
- **Stale click.** The buttons call `AgentRequestStore.choose`. A request that
  was answered or closed in the meantime gives the message "This request was
  already answered." (an answer that is not valid gives "This answer is
  unavailable. Open the terminal to continue."). The message shows above the
  rows with a "Dismiss" button.
- **Compact button row (2026-11-20, approval peek work).** The row now has a
  header (agent icon and terminal title), the title in amber, the command in a
  monospaced box (still whole, still selectable), the muted folder, reason and
  permission lines, and one button row from `CompanionRequestActions`: Deny,
  the primary answer (amber `CompanionAllowButtonStyle`; a command reads
  "Allow", a permissions request keeps "Allow for this turn"), and a "More
  actions" menu (`ellipsis`) with the other answers ("Allow for this session",
  "Deny and stop") and "Open terminal". A terminal-only request shows one
  "Open terminal" button. Questions keep their list, with "Answer" and "Open
  terminal". Do not use `.borderedProminent` for the primary button:
  `ThemedControlStyleScanTests` bans it (it paints the system accent).
- **Hint line.** A "Needs you" row in the Up next waiting list that has a
  window and no request shows a muted second line
  (`CompanionUpNextContent.needsYouHint`): "Turn on Answers from Up next in
  Settings to answer here" for Claude Code while that switch is off, else
  "Answer in the terminal". The row height is now at least 26 pt, not fixed.

**20. Approval peek (2026-11-20).** NOT checked in the GUI (launch only).
Decision: the peek amendment of
[`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md).
Code: `ApprovalPeekModels.swift` (pure), `ApprovalPeekController.swift`,
`ApprovalPeekView.swift` in `Sources/RafuApp/Notch/`. Tests:
`Tests/RafuAppTests/ApprovalPeekModelsTests.swift`.

- **What.** When a request is pending, a 360 pt black card (radius 18) hangs
  6 pt below the anchor: the notch rectangle, Rafu's island pill
  (`NotchIslandGeometry.restingFrame`), the plain-display pill, or the status
  item's window frame (a zero-height top-centre rectangle when macOS hid the
  item). The full panel does not open and Rafu does not activate. Up to two
  blank cards show behind it (6 pt lower each, scale 0.96 and 0.92, opacity
  0.6 and 0.35), with "1 of N", previous and next.
- **When.** Setting "Show approval peek" on (`notchApprovalPeekEnabled`,
  default on), a companion surface exists, the companion panel is not open and
  the menu bar card is not shown. The card stays until the request closes, the
  person answers, or the person closes it (the close button and Escape hide
  the full stack; a later request shows it again; the badge and Up next stay).
  There is no auto-dismiss timer. While the peek shows, the bell drop-down
  does not show (`WorkspaceSession.notifyIfNeeded(for:)`), and the drop-down
  is dismissed when the peek appears.
- **Window.** One `NotchHUDPanel` (no shadow; the card draws its own) of the
  card plus 140 pt side gutters and 16 pt below, so a dragged card does not
  clip. The gutters and the strip below pass clicks through
  (`ApprovalPeekHostingView.hitTest`).
- **Observation.** `withObservationTracking` reads the store, the panel and
  popover state, the presence and the setting, and reads `allAgentRows` only
  while a request is pending. The tracked closure only reads; the controller
  applies the result after it, so a write cannot re-trigger the tracking.
  Defaults that are not observed (the companion switch) are re-read on each
  `activateIfEnabled()`.
- **Fit rule (changed 2026-11-21).** `ApprovalPeekFit`: ASCII counts 1
  column, a tab 8, any other scalar 2; 44 columns per line. A command fits in
  10 wrapped lines (`maxCommandLines`), the text of a file change (one header
  line with the action and the path, then the content or diff;
  `ApprovalPeekText.fileChangeText`) in 10 wrapped lines (`maxBodyLines`), a
  folder in 88 columns, permission lines in 4 wrapped lines total. The measured
  card may be at most `ApprovalPeekGeometry.maxCardHeight(visibleFrame:)` =
  `max(260, min(420, 0.45 * visible height))`; 260 is
  `defaultMaxCardHeight` (used before the screen is known). One question with
  4 or fewer choices, at most 44 label columns and at most 120 characters of
  text shows choice buttons; any other question shows "Answer in Up next".
- **Three card sizes (2026-11-21, replaces Review).**
  `ApprovalPeekContent.resolve(request:decision:oversize:isExpanded:)` gives
  `.answer` when the request fits (the whole text, Allow, Deny, the menu),
  `.needsExpand` when it does not and the person has not expanded it (the text
  cut to 2 lines, "Show all" instead of Allow, a menu with no accept answer),
  and `.expanded` after the click (the whole text in a selectable
  `ScrollView`, at most `expandedBodyHeight` = 220 pt, with Allow active; the
  button row stays outside the scroll area). Only `.needsExpand` and the
  measured-oversize rule cut text.
- **Expand state machine.** `ApprovalPeekController.expandedKeys` holds the
  requests the person expanded. `expand(_:)` ignores a click during the 0.5 s
  click guard and inserts the key. A key leaves the set where `oversizeKeys`
  clears (the request is no longer pending), so a new card always starts
  collapsed, and nothing but a click expands. `cardHeightChanged` never marks
  an expanded card oversize. `review(_:)` stays for "Answer in Up next" only.
- **Swipe rule.** Right swipe (`allowsSwipeRight`) is on for `.answer` and
  `.expanded` only. Left swipe (Deny) is on wherever Deny exists
  (`.answer`, `.needsExpand`, `.expanded`).
- **Safety.** Every answer (button, choice, swipe) goes through
  `ApprovalPeekController.answer`, which returns at once during the 0.5 s
  `ApprovalClickGuard` quiet interval after the shown card changed, then calls
  `AgentRequestStore.choose`. A drag or two-finger swipe that starts in the
  quiet interval is ignored. The panel shows with `orderFrontRegardless()` and
  is not key; a click in the card, or pointer movement over it after the quiet
  interval, makes it key (`ApprovalKeyEngagement`). Allow has no default-action
  shortcut, and the first control is the terminal title.
- **Swipe.** Drag right is the primary answer, left is Deny
  (`ApprovalSwipePolicy`): minimum drag 12 pt, a first move more vertical than
  horizontal is ignored, the label ("Allow" or "Deny", with a symbol) shows
  from 24 pt and is bold at 120 pt, the tilt is `x / 15` clamped to 8 degrees,
  the green or red tint grows to 0.35. Only the distance at release decides
  (120 pt); velocity and the predicted end are not used. A "Show all" card
  rubber-bands to the right (at most 24 pt, no label). Terminal-only, choice
  and "Answer in Up next" cards do not swipe. On a commit the card flies
  ±440 pt in 0.22 s and the next card shows; under Reduce Motion it does not
  tilt and fades in 0.15 s. Two-finger swipe: SwiftUI has no scroll-wheel
  gesture, so `ApprovalPeekHostingView.scrollWheel(with:)` gives the events to
  the controller (precise deltas only, no momentum phase, start at `.began`,
  commit at `.ended`). The finger direction uses `+scrollingDeltaX` when
  `isDirectionInvertedFromDevice` is true, else `-scrollingDeltaX`. NOT
  checked on a device.
- **Glow.** `companionGlowBorder(..., tone:)` with `CompanionGlowTone`:
  `.waiting` (theme warning, amber) on the top card with the slow sweep and a
  fast sweep for each new card; the leaving card uses `.allowed` (success) or
  `.denied` (error) and shows the word "Allowed" or "Denied" for 0.35 s.
  Increase Contrast keeps the solid `borderStrong` line for every tone.
- **VoiceOver.** A new card that the person did not select posts
  `NSAccessibility` `.announcementRequested` (high priority):
  "Codex needs approval: npm test", "... needs approval: Grant permissions",
  "... needs approval: Apply file changes to <path>" (a terminal-only file
  change says "Apply file changes. Open the terminal to answer."),
  "... asks: <question>". The back cards are hidden from VoiceOver. Every
  swipe answer also has a button. The request box reads as one element with the
  whole text: a command "<agent> asks to run <command>", a file change
  "<agent> asks to write <path>. New content: <body>" or "<agent> asks to change
  <path>. Diff: <body>". "Show all" is labelled "Show the whole request".

## Why it matters

The companion is a persistent, always-on overlay near the menu bar; any
regression in click-through, focus, or observer teardown is now
always-visible rather than confined to an on-demand feature. The
usage-file shapes are the one part of this feature that depends on two
external tools whose on-disk formats Rafu does not control and which may
change without notice.

## Reproduction or evidence

- Notch geometry values probed directly via `NSScreen` properties on the
  verification machine (see figures above).
- Click-through verified by dispatching real `CGEvent` clicks against a
  live menu bar menu while the companion strip was resting, confirming
  the click reached the menu instead of being consumed by the panel.
- Focus non-theft verified by confirming `makeKey()` has exactly one call
  site (`engageReply()`) and that wing-click code paths never set
  `allowsKeyStatus`.
- Real on-notch-hardware GUI verification pass covering all companion
  states (resting, peek/hover, pinned, attention feed, usage tiles) with
  0 build warnings and lint clean.
- The editors-search key-status arbitration (rule 8) was verified with a
  real on-notch-hardware screenshot pass alternating focus between the
  feed reply field and the new search field, confirming the panel stays
  key throughout the hop instead of resigning mid-transition; the full
  suite passed at 1072 tests in both `swift test` and `swift test
  --no-parallel`, 0 build warnings, lint clean.

## Verification

```bash
swift build
swift test
swift test --no-parallel
rg -n "makeKey\(\)" Sources/RafuApp
rg -n "auxiliaryTopLeftArea|auxiliaryTopRightArea|safeAreaInsets" Sources/RafuApp/Notch
rg -n "isReplyEngaged|isSearchEngaged|updateKeyStatus|clearKeyEngagement" Sources/RafuApp/Terminal/NotchCompanionModel.swift
rg -n "filteredEditorRows|searchFieldThreshold" Sources/RafuApp/Terminal/NotchCompanionPolicy.swift Sources/RafuApp/Terminal/NotchCompanionModel.swift
rg -n "NotchScreenSelection|currentMetrics" Sources/RafuApp/Terminal
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Notch/NotchCompanionModel.swift`
- `Sources/RafuApp/Notch/NotchHUDPolicy.swift`
- `CompanionGlowPolicy`, `companionGlowBorder`, `CompanionOutline`,
  `CompanionChromeMetrics`, `CompanionAgentCardView` (rules 13 to 17), and
  `NotchHUDPanel.hitOutline` in `NotchHUDWindow.swift`
- `Sources/RafuApp/Notch/AgentUsageProvider.swift` (and
  `CodexUsageProvider`/`ClaudeUsageProvider`)
- `Sources/RafuApp/Terminal/NotchCompanionModel.swift`
  (`updateKeyStatus()`/`clearKeyEngagement()`, `isReplyEngaged`/
  `isSearchEngaged`, `visibleEditorRows`, `isSearchFieldVisible`,
  `setSearchQuery(_:)`)
- `Sources/RafuApp/Terminal/NotchCompanionPolicy.swift`
  (`CompanionEditorRow.branch`, `filteredEditorRows(_:query:)`)
- `Sources/RafuApp/Views/NotchCompanionView.swift` (`CompanionSearchFieldView`
  pinned above the internal `ScrollView`)
- `Sources/RafuApp/Terminal/NotchHUDGeometry.swift` (`NotchScreenSelection`)
  and `Sources/RafuApp/Terminal/NotchHUDWindow.swift`
  (`NotchScreenAdapter.currentMetrics()`) — rule 11's multi-display anchor
- [`terminal-notch-hud.md`](../plans/phases/terminal-notch-hud.md) (stages
  NC-A…NC-E, editors-search follow-up)
- [`0016-terminal-attention-notifications.md`](../decisions/0016-terminal-attention-notifications.md)
  (2026-07-22 amendment)
- [`terminal-signals-and-shell-catalog.md`](terminal-signals-and-shell-catalog.md)
  (v1 attention HUD stack this builds on)
- [`nonisolated-extension-isolation-trap.md`](nonisolated-extension-isolation-trap.md)
  (the general Swift-concurrency gotcha found while building NC-A)
- [`agent-hooks-and-now-playing.md`](agent-hooks-and-now-playing.md) (X11:
  hook-based agent phases in the notch, "Other agents", and the system Now
  Playing source with its Music/Spotify fallback)
- [`0042-answer-agent-requests-from-up-next.md`](../decisions/0042-answer-agent-requests-from-up-next.md)
  (rule 19, approval rows), with
  [`codex-app-server-approvals.md`](codex-app-server-approvals.md) and
  [`claude-permission-request-hook.md`](claude-permission-request-hook.md)
