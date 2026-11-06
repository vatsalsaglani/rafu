# Ensemble presence and trust (UX Round B)

- **Applies to:** the Ensemble tab's agent pill and the Dock badge
  (`EnsembleTabPill`, `EnsembleTabPillButton`, `DockAttentionBadge`), the
  summary and silhouette card faces (`CanvasCompactFaceMetrics`,
  `AgentStatusDot`), the Agent control pill (`AgentControlPresentation`),
  agent-edit provenance (`CanvasAgentProvenanceStore`,
  `CanvasAgentNoticeText`, `CanvasAgentUndoGate`), the status-bar memory chip
  (`MemorySettling`, `MemoryChipPresentation`), and the Resources Ensemble rows
  (`EnsembleContentMetric`).
- **Last verified:** Apple Swift 6.4.2, macOS 27.0.1, on 2026-11-07, branch
  `ux/round-b` from `b80e899`.

## Rule or observed behaviour

### One fold for every board-level count

`CanvasAgentSummaryItem(board:session:)` resolves each terminal card through
`CanvasCardCommands.agentCardStatus(pane:in:)`. The Ensemble bar, the tab pill,
the tab hover preview and the Dock badge all use it, so they cannot disagree
about one terminal.

### Tab pill and Dock badge (E1)

- The tab shows one pill after its title: "N failed" (`error` tint) or
  "N needs you" / "N need you" (`warning` tint). Failed outranks needs you
  (ADR 0029 precedence). No pill at zero. Counts only; never a card name.
- The pill is a `Button` in its own type in `CanvasAgentSummaryItem.swift`.
  `CanvasEditorTabItem.swift` must not contain `.buttonStyle(.plain)` or
  `} label: {` (`EditorTabAndGroupPresentationTests.tabLabelsAreNotButtons`).
- A click selects the tab when it is not selected, then calls
  `session.focusCanvasCard(_:in:)` on the first card the pill counts — the
  same call as the bar's jump menu.
- The tab's accessibility value gets the pill words. The hover preview shows
  "1 needs you · 1 failed" when there are counts, else "Needs approval".
- Dock: `NSApp.dockTile.badgeLabel` is the sum of needs-you and failed cards
  over every open Ensemble in every **visible** workspace window, capped at
  "99+", and `nil` at zero. There is no timer and no observer: each Ensemble
  tab calls `DockAttentionBadge.refresh()` from
  `.onChange(of: [needsYou, failed], initial: true)`, and
  `refreshSoon()` (one `Task.yield()` later) from `.onDisappear`. The label
  is written only when it changes.
- A closing window is ordered out before its views go away, so `refresh()`
  skips entries whose `window?.isVisible != true`. `sessionSnapshots()` is
  not used because it does not expose the window.

### Readable faces when zoomed out (B4)

Card content is scaled by the viewport, so `v / scale` board units are `v`
screen points. `CanvasCompactFaceMetrics(face:scale:)` returns board units for
these screen sizes:

| Value | Screen points | Face |
|---|---|---|
| glyph | 20 | summary (25–50 %) |
| glyph | 24 | silhouette (< 25 %) |
| status dot | 6 | silhouette |
| pill / state / line font | 11 | summary |
| padding | 12 | both |
| title font | `CanvasZoomMetrics.titleFontSize(scale:)` (11 pt floor) | both |

- A silhouette shows its title only when `card.rect.width × scale ≥ 60`;
  a narrower card shows the glyph alone, never a clipped title.
- The silhouette glyph is capped at 60 % of the card's shorter side
  (`fittedGlyph`) and the silhouette has no content padding, so a card at
  10 % (a 380 × 260 card is 38 × 26 screen points) is not cut by its own edge.
- The silhouette dot (`AgentStatusDot`) appears only for an agent status.
  A plain running shell gets no dot. The dot has a 1 pt surface ring
  (1.5 pt `borderStrong` under Increase Contrast), is hidden from
  accessibility, and does not hit-test; the face keeps its full-rect gesture
  and context menu.
- `AgentStatusPill(fontSize:)` and `AgentActivityGlyph(size:)` scale their
  padding, spacing and arc stroke with the font, so the pill keeps its shape
  at any zoom. Defaults (11 / 9) keep the card header unchanged.

### Agent control pill (B8)

Glyph plus word: `hand.raised` Off, `questionmark.circle` Ask,
`checkmark.circle` Allow. While approvals wait: "Ask · 2 waiting", a
`warning.opacity(0.18)` fill and `textPrimary` text. When the waiting count
grows, the capsule dips to 0.6 opacity and back (`RafuMotion.stateCrossFade`,
300 ms), once per increase, never under Reduce Motion. The popover still
opens on increase.

### Agent-edit provenance and the notice's Undo (B9)

- `CanvasAgentActions.perform` snapshots the board's cards and links before
  `execute`, and after a successful non-read call hands the call, response
  and snapshot to `CanvasAgentProvenanceStore.shared.noteEdit`.
- The card is `response.toolResult.nodeID ?? call.nodeID`. When neither names
  a card on the board, nothing is recorded — no guess.
- Verbs: note/node/terminal/frame create → "added"; `node_update` →
  "renamed" (title only), "moved" (x/y only), "resized" (width/height),
  "changed" (mixed); `note_write` → "wrote"; `mermaid_set` → "changed".
  Removal, links, link state, typing, start, export and `diagram_build` have
  no verb and leave no mark (the activity log keeps them).
- The record (vendor name "Claude"/"Codex", provider, action title, verb,
  date, `changeStamp`) shows a header badge with the vendor mark for 8 s
  (`CanvasBoardNotice.lifetime`), only on live faces (≥ 50 %). The badge's own
  `.task` prunes the store after the lifetime. The card's accessibility value
  adds "Added by Claude" while the record is visible. The store keeps at most
  200 records; nothing is saved.
- The notice reads "Claude added Note 3" (`.info`). Names only: the card
  title passes through `CanvasAgentText.singleLine(_:limit: 40)`; never note
  text, prompts or output.
- **Undo is offered only when the call made a board undo step:** `canUndo`
  and the cards or links differ from the snapshot. A `note_write` into an
  open note goes through the note's own undo manager, not the board's, so it
  gets a notice without Undo — a board Undo there would revert an unrelated
  earlier step.
- **Undo gate.** `CanvasAgentUndoGate` holds the cards and links right after
  the edit. Undo runs, and the button is enabled, only while the board's
  cards and links still equal them. The gate is content, not `changeStamp`:
  `setViewport` and `markNoteEdited` also bump `changeStamp`, so a stamp gate
  would take Undo away when the user only pans or zooms. Undoing a later edit
  restores equality, and then the agent's step is again the newest undo step,
  so Undo is honest again. `CanvasBoardNoticeView` asks
  `allowsAction(noticeID:board:)`; a notice without a gate is unaffected.
  Gates are replaced per board, so they stay bounded by the number of boards.
- `board.edit` already clears the notice, so in practice the gate covers the
  paths that change content without `edit` (the note save flush, a race with
  the Undo click).

### Settled memory (R1)

- `ResidentMemoryMonitor.refresh()` feeds `MemorySettling` at most once per
  4.5 s, because the Resources popover also calls `refresh()` every 2 s; the
  median must keep meaning "the last 30 s of 5 s samples".
- `settled` is the median of the last 6 samples (the live value until 6
  exist). `peak` is the highest sample since launch. `trend` compares the
  median of the last 6 with the median of the first 6 of a full 24-sample
  ring (two minutes); more than ±15 % shows `arrow.up.right` /
  `arrow.down.right` at 8 pt. Colour never changes.
- The tooltip and accessibility value give "Live · Peak · Settled (median of
  30 s)". The Resources summary keeps the live footprint; its composition
  explanation adds the settled value.

### Resources Ensemble rows (R2)

- `WorkspaceContentMetrics.ensembles` has one `EnsembleContentMetric` per open
  board of the window, in title order, including empty boards (they are open
  tabs). Row: title, "N cards", note
  "2 images · 1 terminal · 1 web live · ≈ 4.2 MB images (shared)" with zero
  parts left out.
- `CanvasImagePool` is **one per `WorkspaceSession`** (`session.canvasImages`),
  not per board. Its `reservedBytes` go on the first row only, with
  "(shared)" when the window has more than one Ensemble. Do not split it.
- Live web surfaces are `canvasResources[board.id].webs` entries whose
  `webView != nil`.

## Why it matters

Agents act on the board while the person looks elsewhere. The pill, the Dock
badge and the readable faces show where attention is needed without opening
each board; the provenance badge and the gated Undo make every agent change
visible and safely reversible; the settled memory chip stops a short spike
from reading as a leak.

## Reproduction and evidence

Unit tests:

- `Tests/RafuAppTests/Canvas/CanvasAgentSummaryTests.swift` (tab pill).
- `Tests/RafuAppTests/DockAttentionBadgeTests.swift`.
- `Tests/RafuAppTests/Canvas/CanvasCompactFaceMetricsTests.swift`.
- `Tests/RafuAppTests/Canvas/CanvasAgentControlPresentationTests.swift`.
- `Tests/RafuAppTests/Canvas/CanvasAgentProvenanceTests.swift`.
- `Tests/RafuAppTests/Canvas/CanvasAgentActionsTests.swift`
  (`agentEditProvenanceAndUndo`, `readLeavesNoMark`).
- `Tests/RafuAppTests/MemorySettlingTests.swift`.
- `Tests/RafuAppTests/MemoryCompositionTests.swift`.
- `Tests/RafuAppTests/WorkbenchChromeRedesignTests.swift`
  (`hoverPreviewContentBuilders`).

## Verification commands

```bash
./script/build.sh
./script/test.sh
swift test --filter "CanvasAgentProvenance|MemorySettling|CanvasCompactFaceMetrics"
./script/build_and_run.sh --verify
```

## Related

- Code: `Sources/RafuApp/Canvas/Views/CanvasAgentSummaryItem.swift`,
  `Canvas/Views/CanvasEditorTabItem.swift`, `Support/DockAttentionBadge.swift`,
  `Canvas/Domain/CanvasCompactFaceMetrics.swift`,
  `Canvas/Views/AgentActivityGlyph.swift`, `Canvas/Views/CanvasCardViews.swift`,
  `Canvas/Views/CanvasAgentControlItem.swift`,
  `Canvas/Integration/CanvasAgentProvenance.swift`,
  `Canvas/Integration/CanvasAgentActions.swift`,
  `Canvas/Views/CanvasBoardNoticeView.swift`, `Support/MemorySettling.swift`,
  `Views/ResourcesView.swift`, `Views/WorkspaceStatusBar.swift`,
  `Services/MemoryComposition.swift`.
- ADRs: [0029](../decisions/0029-agent-status-vocabulary.md) (amended
  2026-11-07), [0026](../decisions/0026-canvas-live-session-links.md) (unchanged: links
  get no provenance mark).
- References: [`canvas-interaction.md`](canvas-interaction.md),
  [`memory-footprint-and-timer-tolerance.md`](memory-footprint-and-timer-tolerance.md).
