# Notch companion: geometry, click-through, focus non-theft, usage-file shapes

- Applies to: `Sources/RafuApp/Notch/**` (resting strip, peek panel,
  `NotchCompanionModel`, `AgentUsageProvider`/`CodexUsageProvider`/
  `ClaudeUsageProvider`), and the ADR 0016 attention-surface arbitration
- Last verified: Swift 6.2, macOS 26, 2026-07-22 (real on-notch-hardware
  GUI verification)

## Rule or observed behavior

**1. Notch geometry has no public API — it is derived, not queried.**
There is no `NSScreen`/`AppKit` API that returns "the notch rect."
Geometry is derived from `NSScreen.safeAreaInsets.top` (the band height)
and the horizontal gap between `NSScreen.auxiliaryTopLeftArea` and
`auxiliaryTopRightArea` (the notch width sits between them). If either
auxiliary area is `nil`, there is no notch, and the companion turns
itself off entirely (`Show notch companion` has no visible effect on
non-notch displays — no second preference, no manual override). Probed on
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
  windows and never fabricates a percentage.
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
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Notch/NotchCompanionModel.swift`
- `Sources/RafuApp/Notch/NotchHUDPolicy.swift`
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
- [`terminal-notch-hud.md`](../plans/phases/terminal-notch-hud.md) (stages
  NC-A…NC-E, editors-search follow-up)
- [`0016-terminal-attention-notifications.md`](../decisions/0016-terminal-attention-notifications.md)
  (2026-07-22 amendment)
- [`terminal-signals-and-shell-catalog.md`](terminal-signals-and-shell-catalog.md)
  (v1 attention HUD stack this builds on)
- [`nonisolated-extension-isolation-trap.md`](nonisolated-extension-isolation-trap.md)
  (the general Swift-concurrency gotcha found while building NC-A)
