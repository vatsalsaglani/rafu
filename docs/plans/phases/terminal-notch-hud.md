# T-F v2 — Notch Companion

Status: Implemented (2026-07-22). All five stages NC-A through NC-E are
shipped, advisor-reviewed (no P0/P1 findings), and verified with real
on-notch-hardware GUI verification. The v1 event-driven HUD (appears on
attention, seamless housing merge, bounded snippet, inline reply,
quiescence detection) remains the attention layer, now unified visually
with the companion shell. Baseline: 1054 tests passing in both
`swift test` and `swift test --no-parallel`, 0 build warnings, lint clean.

## Stage outcomes (2026-07-22)

- **NC-A** — `NotchCompanionModel` (weak multi-session registry, editor
  row/attention-feed derivation, hover/pin policy) and wing geometry
  shipped, pure and headless-tested. Uncovered the
  `nonisolated`-does-not-propagate-into-a-bare-`extension` runtime trap
  (see [`nonisolated-extension-isolation-trap.md`](../../references/nonisolated-extension-isolation-trap.md));
  fixed by moving the affected pure statics into their type's primary
  body.
- **NC-B** — Resting strip window shipped: click-through everywhere
  except the wings (AppKit `hitTest` override converting to screen
  coordinates), hover-to-peek expansion with the editors list, and
  click-to-focus-window. Click-through verified with real `CGEvent`
  clicks against a live menu bar menu, not just view-hierarchy state.
- **NC-C** — Attention feed in the peek panel, v1 drop-down arbitration
  (deterministic: peeked/pinned panel takes the bell as a feed card,
  resting state gets the v1 drop-down, never both), and the git
  one-liner (`⎇ main · 3± · ↑2`) shipped.
- **NC-D** — Usage providers shipped: Codex real 5h/7d rate-limit
  percentages from rollout files, Claude 5h/7d token totals from
  transcript `usage` objects (Claude exposes no rate-limit percentage, so
  its tile never fakes one). Parsers pure/injectable, bounded, off-main,
  60s TTL.
- **NC-E** — "Show notch companion" Settings toggle (default on) shipped;
  on non-notch displays the strip never renders (geometry derivation
  returns nil) rather than introducing a second preference. Polish pass
  covered Reduce Motion/Reduce Transparency/Increase Contrast and a
  real-hardware GUI verification pass across all companion states.

## Hardening applied post-implementation

Two P2-level items from the advisor's read-only review were applied
before handoff:

1. Per-panel notification-observer teardown on screen-parameter-driven
   panel recreation (the companion panel, unlike the persistent v1
   drop-down panel, is recreated when screen parameters change, so its
   observers must be attached/removed per-instance rather than once for
   the app's lifetime).
2. The attention feed's coupling to the existing `.hud` attention-surface
   preference was confirmed as intentional (not a bug) and documented so
   it is not mistaken for one later — see the ADR 0016 amendment and
   [`notch-companion.md`](../../references/notch-companion.md).

## Post-NC-E follow-ups (2026-07-22)

Three small increments landed after the NC-A…NC-E stage sequence closed,
each advisor→implementor→documentor reviewed and verified:

- **Resting-strip shadow removal.** `NSPanel.hasShadow` is set `false`
  while resting (`NotchCompanionModel`'s `presentPanel`/`reposition`),
  because a panel shadow paints a rim light around all edges — including
  the top — that reads as a bright outline separating the strip's black
  from the physical notch it must appear seamless with. `reposition()`
  re-enables the shadow (`hasShadow = true`) for the peeked/pinned panel,
  where depth against window content below is wanted.
- **Peek height cap + internal scroll.** The peek/pinned panel's frame is
  capped at 0.6-of-screen height (`NotchCompanionGeometry.peekPanelFrame`)
  so many editor windows or feed cards cannot march the panel off the
  bottom of the screen; overflow scrolls inside an internal
  `ScrollView(.vertical)` (`NotchCompanionView`) instead of growing the
  window.
- **Editors-list search/filter.** A pinned search field
  (`CompanionSearchFieldView`) appears above the internal scroll once
  `editorRows.count >= 6` or a query is already active, filtering the
  EDITORS LIST (not the usage strip or attention feed) by workspace name
  OR raw git branch, case- and diacritic-insensitive substring
  (`CompanionEditorRow.filteredEditorRows`). `CompanionEditorRow` gained a
  raw `branch: String?` separate from the decorated `gitSummary`, which is
  lossy for detached/unborn states. The query is ephemeral — cleared on
  every collapse to `.resting`. Clicking a filtered row still focuses that
  window. Introducing the field's own focus surfaced a key-status
  arbitration nuance (two independently focusable fields — the feed reply
  field and the new search field — on one non-activating panel): see
  [`notch-companion.md`](../../references/notch-companion.md) rule 8
  (`updateKeyStatus()`/`clearKeyEngagement()` arbiter). Verified: 1072
  tests passing in both `swift test` and `swift test --no-parallel`, 0
  build warnings, lint clean, real on-notch-hardware screenshot pass.

## Owed verification

VoiceOver discoverability of the resting/peek states while NOT key
(i.e., before the reply field engages `allowsKeyStatus`) has not yet been
empirically tested with real VoiceOver. The accessible fallback path
(Terminals panel, Source Control panel, v1 drop-down) is unaffected and
already key-able. Recorded as an open item, not a resolved claim.

Depends on: terminal-manager phase (T-A…T-E), ADR 0016, the shipped v1 HUD
window/geometry/policy stack, `WorkspaceWindowRegistry`,
`TerminalAttentionCenter`.

## Vision

The notch stops being dead space and becomes Rafu's **always-on companion
strip**: a quiet, housing-black presence that tells you at a glance how
many editors are open and whether anything needs you — and on hover,
expands into a control surface where you can jump to any editor, read what
an agent just said, reply to it, and see your Claude/Codex usage budget.
The user lives in terminals running agents; the notch is where "is anything
waiting on me?" gets answered without switching windows.

## Prior art and the license line

UX inspiration: [open-vibe-island](https://github.com/Octane0411/open-vibe-island)
(session cards, usage strip, expand-on-demand) and
[agent-notch](https://github.com/realfishsam/agent-notch) (click-through
resting state). **open-vibe-island is GPL v3 and Rafu is MIT: NO code may
be copied from it — ideas and interaction patterns only.** Anyone found
porting its source must stop and rewrite from the behavior description in
this document. (agent-notch's technique notes are already absorbed; same
rule applies.)

Structural difference that shapes everything below: those tools monitor
agents in OTHER apps' terminals via hooks/polling. Rafu owns its terminals
(synchronous bell/OSC/quiescence signals, direct pty reply) and its
editors (live git state, window focus), so the companion is richer and
faster for Rafu sessions — and deliberately does not try to see non-Rafu
terminals (a future hooks phase could; out of scope, see Non-goals).

## The three states

### 1. Resting (always present, the default)

A slim housing-black strip hugging the notch — the notch band plus two
small "wings" (~90pt each side), total width ≈ notch + 180pt:

- **Left wing:** the Rafu glyph (the zigzag mark, theme-accent tinted) +
  the number of open editor windows ("3").
- **Right wing:** nothing when calm. When sessions need attention: an
  accent dot + count ("2"), the same signal as the rail badge.
- Height = the band (33pt). Nothing hangs below. Blends with the housing;
  the wings render over the menu bar's empty center region.
- **Click-through everywhere except the wings** — resting must never
  block menu items. Wings are hover/click targets.
- Reduce Transparency/Increase Contrast: the wings stay solid black with
  a hairline edge; the glyph/count carry the state, never color alone.
- A Settings toggle ("Show notch companion") controls existence; default
  ON on notched displays, OFF on non-notch displays (a permanent floating
  bar under an external monitor's menu bar is clutter; the v1 attention
  HUD still appears there on demand).

### 2. Peek (hover, or click to pin)

Hovering either wing (300ms dwell) — or clicking, which PINS it open —
expands the strip downward into the companion panel. Mouse-out (400ms
grace) collapses unless pinned; Escape always collapses. Spring expand,
cross-fade under Reduce Motion.

Panel anatomy, top to bottom (housing-black shell, THEME-TOKEN content —
cards use `cardBackground`, text uses the text tokens, accents/attention
use `accent`, session colors keep their border language from the panel):

1. **Usage strip** (when data exists; hidden entirely otherwise):
   `Claude · 5h ▓▓░ 128k tok · 7d 1.2M tok    Codex · 5h 17% · 7d 6%`
   — Codex shows true percentages, Claude shows token volume (see Data
   sources for why they differ). Muted, single line, tabular numerals.
2. **Editors list** — one row per open workspace window, from
   `WorkspaceWindowRegistry`:
   - workspace name + window number
   - **git one-liner** (the "git summary" question — yes, but exactly one
     line): `⎇ main · 3± · ↑2` (branch, dirty count, ahead/behind), from
     the session's existing `gitSnapshot`/`gitBranchSnapshot`. No graphs,
     no history — the Source Control panel is one click away.
   - terminal chips: `▶ 2` running, `● 1` attention (accent), `◼ 1` exited
   - Click row → focus that window (`makeKeyAndOrderFront` via the
     registry). Click the attention chip → focus the window AND reveal the
     belling session's tab.
3. **Attention feed** — one card per session currently in `.bell`, newest
   first, ACROSS ALL WINDOWS (this replaces v1's queue-of-one when the
   panel is open; the resting dot still shows the count):
   - session color border, display name, editor name, relative time
   - the bounded snippet (same 6-line/512-byte read, same privacy rules)
   - inline reply field + Send (existing sanitize → deliverReply path)
   - "Open" button → focus window + reveal tab (clears `.bell`)
4. **Footer:** "New Terminal" (focused window) · "Show Terminals panel".

### 3. Attention (event-driven, unchanged v1 behavior, restyled)

When a session bells and the panel is NOT open: the v1 drop-down appears
under the notch exactly as shipped (compact → expanded, reply, timers),
now visually unified with the companion (same shell, same card language).
If the user is hovering/pinned, the event lands in the attention feed
instead of spawning the separate drop-down. The
`TerminalAttentionSurface` preference gains no new cases; the companion
strip has its own toggle.

## Data sources (verified on this machine, 2026-07-22)

- **Editors / git / terminals:** already live in-process
  (`WorkspaceWindowRegistry`, per-session `gitSnapshot`,
  `WorkspaceTerminalManager`). A new `@MainActor` aggregation model
  (`NotchCompanionModel`) holds WEAK session references (registered
  alongside `TerminalAttentionCenter`) and derives rows; all derivation
  pure and headless-testable.
- **Codex usage:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` contains
  `rate_limits` snapshots with `primary`/`secondary` windows carrying
  `used_percent`, `window_minutes` (verified: a real rollout on this
  machine shows `used_percent: 0.0, window_minutes: 10080`). Parse the
  NEWEST rollout's latest snapshot, read-only, at panel-open + every few
  minutes while pinned. True percentages.
- **Claude usage:** `~/.claude/projects/**/*.jsonl` transcripts carry
  per-message `usage` token objects (verified) but NOT rate-limit
  percentages. v1 of the strip therefore shows **token totals** for
  trailing 5h/7d windows (ccusage-style aggregation, newest files only,
  bounded scan). Exact percentages would need Claude's statusline bridge
  (config-touching, opt-in) — explicitly deferred; the strip's Claude
  tile says "tokens", never fakes a %.
- Privacy rules: usage parsing reads TOKEN COUNTS and timestamps only —
  never prompt/response content; nothing leaves the machine; nothing is
  cached to disk by Rafu. Reading other tools' local files is a new
  capability → note in the ADR amendment.

## Non-goals (v2)

- Permission-approval buttons (open-vibe-island's Yes/No/Always Allow):
  requires installing PreToolUse hooks into agent configs — a
  config-touching integration deserving its own phase (T-G) with an
  explicit opt-in installer flow. Not here.
- Seeing agents in non-Rafu terminals (Ghostty etc.) — same future hooks
  phase.
- Claude statusline bridge for exact percentages — deferred, opt-in.
- Music/media/clipboard notch gadgets. Rafu is a repository companion.

## Architecture deltas from shipped v1

| Piece | v1 (shipped) | v2 delta |
|---|---|---|
| Window | one event panel, appears on bell | + a persistent resting strip (same `NotchHUDPanel` class, second instance or widened single window with three layout states — implementor's call; click-through regions via `ignoresMouseEvents` + hit-test override) |
| Geometry | notch rect + hudFrame | + wing layout (aux-area math already probed), + expanded panel sizing driven by content |
| Model | `NotchHUDController` (event, queue-of-one) | + `NotchCompanionModel`: weak multi-session registry, editor rows, attention feed, usage tiles; controller consumes it |
| Policy | dismiss/queue/surfaces | + hover dwell/grace timing policy (pure), + pin state, + "feed vs drop-down" arbitration |
| Usage | — | `AgentUsageProvider` protocol + `CodexUsageProvider` / `ClaudeUsageProvider` (pure parsers over injected file contents; the ONLY file readers are thin adapters) |

Focus rules, reply path, snippet bounds, privacy: unchanged from v1/ADR
0016. The strip's wings accept clicks without activating the app;
keyboard focus still moves only when the reply field is engaged.

## Stages

| Stage | Contents | Size |
|---|---|---|
| NC-A | `NotchCompanionModel` + row/feed derivations + hover/pin policy (pure, tested); wing geometry | M |
| NC-B | Resting strip window (click-through, wings, counts) + hover→peek expand with editors list + focus-window action | M/L |
| NC-C | Attention feed in the panel + v1 drop-down arbitration + git one-liner | M |
| NC-D | Usage providers (Codex % first — real data verified; Claude tokens second) + usage strip | M |
| NC-E | Settings toggle, non-notch default-off behavior, polish pass (Reduce Motion/Transparency, VoiceOver), screenshot-verified states | S/M |

Each stage lands with its tests and the standard gates (`swift build` 0
warnings; `swift test` AND `--no-parallel` green; format fix+lint clean;
screenshot-verified GUI pass for every visual state — the empirical
method is mandatory, this is the fourth chrome surface).

## Tests (headless core)

- Wing/panel geometry incl. click-through region math (pure rect logic).
- Hover policy truth table: dwell, grace, pin overrides, Escape.
- Editor-row derivation from N fake sessions (names, git one-liner
  formatting incl. detached/no-repo, terminal chip counts).
- Attention-feed ordering, cross-window aggregation, clear-on-reveal.
- Feed-vs-drop-down arbitration (panel open swallows the event).
- Usage parsers over fixture strings: real codex rollout snapshot shape
  (used_percent/window_minutes), claude usage-object aggregation into 5h/7d
  buckets, malformed/missing files → tile hidden (never a crash, never a
  fake number).
- Registry weak-reference hygiene (closed window drops its row).

GUI-only: everything visual (four states × light/dark × Increase
Contrast), click-through over menu items, focus non-theft, cross-Space
and full-screen behavior, second display.

## Risks

1. A PERSISTENT overlay raises the bar: any flicker, focus theft, or
   menu-bar interference is now always-on. Click-through correctness is
   the top risk; screenshot + real-menu-click verification required.
2. Hover expansion near the menu bar can fight menu tracking — the dwell
   delay and wing-only hit targets exist for this; verify against real
   menu usage.
3. Usage file formats are OTHER TOOLS' internals and will drift: parsers
   must treat every field as optional, version-tolerant, and hide the
   tile on any parse failure. Never block the panel on file I/O — parse
   off-main, cache in memory with a short TTL.
4. GPL contamination (see the license line). Review diffs for lifted code.
5. Unbounded transcript scans: the Claude aggregator must bound work
   (newest N files, size caps, mtime cutoff at the 7d window).

## Documentation on completion (done, 2026-07-22)

- Amended ADR 0016: the companion as the third surface; reading other
  tools' local usage files (new capability, read-only, local-only). See
  the 2026-07-22 amendment in
  [`0016-terminal-attention-notifications.md`](../../decisions/0016-terminal-attention-notifications.md).
- Reference notes: codex rollout `rate_limits` shape, claude transcript
  `usage` shape (as observed, with the drift warning), wing geometry, and
  the click-through/focus/observer-teardown nuances the verification
  revealed — [`notch-companion.md`](../../references/notch-companion.md).
  The `nonisolated`-extension isolation trap found during NC-A was split
  into its own general Swift-concurrency note:
  [`nonisolated-extension-isolation-trap.md`](../../references/nonisolated-extension-isolation-trap.md).
- Updated this doc (stage outcomes above) and the phases README.
