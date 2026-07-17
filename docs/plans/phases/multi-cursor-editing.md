# Lane plan — Multi-cursor editing (Phase 2 deliverable)

## Status

Planned (2026-07-17). One of six post-audit lanes defined in
[`post-audit-worktree-fanout.md`](post-audit-worktree-fanout.md). Runs in a
**dedicated git worktree**. Delivers the named Phase 2 deliverable
"multi-cursor editing" (see
[`phase-2-editor-completeness.md`](phase-2-editor-completeness.md)), which is
untouched today. Each increment is one advisor → implementor → verification →
documentor cycle. File:line anchors reflect the tree on 2026-07-17; the
repository wins over this plan when they disagree.

## Verified baseline

- `RafuTextView` is **deterministically TextKit 1**: `makeTextKit1()`
  (`Sources/RafuApp/Editor/RafuTextView.swift:20–45`) hand-builds
  `NSTextStorage → NSLayoutManager → NSTextContainer`; all geometry uses
  `layoutManager.boundingRect(forGlyphRange:in:)`.
- Existing overrides (complete list): `acceptableDragTypes` (:51),
  `mouseDown` (:121, ⌘-click navigation branch), `updateTrackingAreas`
  (:135), `mouseMoved` (:151), `mouseExited` (:158), `keyDown` (:168),
  `menu(for:)` (:284), `drawBackground(in:)` (:328 — draws **below** glyphs,
  so it cannot host carets). **No** `insertText`/`deleteBackward`/`paste`/
  `drawInsertionPoint`/`NSTextInputClient` overrides exist today.
- The programmatic-edit reference pattern is `toggleLineComment()`
  (`CodeEditorView.swift:440–467`): `shouldChangeText` →
  `textStorage?.replaceCharacters` → `didChangeText()` → `setActionName`.
- Every storage mutation flows through
  `Coordinator.textStorage(_:didProcessEditing:…)` (`CodeEditorView.swift:
  525–547`) → `document.recordEditDelta` + the **non-cancelling serial**
  reparse chain (`SyntaxHighlighter.swift:515–565`), so N sub-edits arrive
  in order at both the LSP delta stream and the tree-sitter actor — a
  multi-caret batch is a legitimate N-delta sequence; **no consumer
  changes**.
- Undo: capped `UndoManager` (`levelsOfUndo = 200`,
  `CodeEditorView.swift:172–189`). Naming a closed group throws — name
  before `endUndoGrouping`.
- Selection restoration is a **single** `restoredSelection: NSRange?`
  (`EditorDocument.swift:76`); multi-caret sets are ephemeral and collapse
  to the primary caret on hibernation — the correct v1 shape, no schema
  change.

## Design summary

An authoritative caret set (`caretRanges: [NSRange]`) owned by
`RafuTextView` is the source of truth. Native `selectedRanges` is driven
from it for highlighting; secondary-caret rendering and typing/delete/paste
fan-out are hand-built (NSTextView draws only one insertion point and does
not fan out typing across ranges). All edit math lives in a pure,
fully-unit-tested `MultiCaretModel`. Every override bails to `super` when
`caretRanges.count <= 1` or `hasMarkedText()` (IME), so the single-caret
path — auto-indent, ⌘/, hover, ⌘-click, bracket matching — is byte-for-byte
unchanged.

**Two runtime spikes gate the rendering path** (resolve at the start of
MC2, record findings in the reference note):

- **Spike A:** does `setSelectedRanges` retain multiple zero-length ranges
  and keep the primary caret blinking, or does AppKit coalesce them?
- **Spike B:** secondary carets via an overlay subview vs. a
  `drawInsertionPoint(in:color:turnedOn:)` override.

## Global rules for this lane

- **Owned paths:** `Sources/RafuApp/Editor/MultiCaretModel.swift` (new),
  `Sources/RafuApp/Editor/MultiCaretOverlayView.swift` (new),
  `Sources/RafuApp/Editor/RafuTextView.swift`,
  `Sources/RafuApp/Editor/CodeEditorView.swift` (additive `Coordinator`
  hunks only), `Sources/RafuApp/Models/EditorDocument.swift` (additive
  action-closure properties only),
  `Tests/RafuAppTests/MultiCaretModelTests.swift` (new),
  `docs/references/multi-caret-editing.md` (new), and this plan document.
- **Shared / integration-owned — do NOT edit until the final increment,
  then land as two minimal additive hunks coordinated with the fan-out
  integration owner:** `Sources/RafuApp/App/RafuAppCommands.swift`,
  `Sources/RafuApp/Models/WorkspaceSession.swift`. Every other lane also
  lands command/session hunks last; the fan-out plan sequences them.
- **Forbidden paths:** `Sources/RafuApp/Editor/Syntax/**` (the reparse
  contract is consumed unchanged), `Sources/RafuApp/LanguageIntelligence/**`,
  `Sources/RafuApp/Markdown/**`, Git services, `Sources/RafuCLI/**`,
  `Sources/RafuCore/**`, `Package.swift`/`Package.resolved`, `AGENTS.md`,
  shared doc indexes (single appends at merge per the fan-out plan).
- Concurrency: no new actors expected; if any cross-actor work appears, the
  `swift-concurrency-pro` review path applies. AppKit interop follows
  `build-macos-apps:appkit-interop` routing.
- Verification per increment: `swift build`, `swift test` (full suite stays
  green — single-caret editor tests are the regression canary),
  `./script/format.sh --fix` then `--lint`;
  `./script/build_and_run.sh --verify` for MC2 onward (editor behavior) —
  never while another lane runs it.
- After each green increment the coordinator stops and asks the user to
  commit. No agent commits.

## MC1 — Pure `MultiCaretModel` (freeze the edit math first)

New `Sources/RafuApp/Editor/MultiCaretModel.swift` (nonisolated, AppKit-free
beyond `NSRange`):

- Sorted-disjoint invariant with a primary index; `normalized()` merges
  overlapping/adjacent ranges, drops duplicate empty carets, clamps to text
  length.
- `applyingReplacement(_:at:)` — one replacement string applied at every
  range: returns sub-edits **already reverse-sorted** (highest location
  first, so earlier offsets stay valid during application) plus the new
  caret set with correct cumulative shifting.
- Occurrence search: `nextOccurrence` (⌘D semantics) and `allOccurrences`
  (⌘⇧L), v1 = literal substring match of the primary selection's text; an
  empty selection first expands via the existing `IdentifierUnderCaret`.
  Bounded: occurrence cap ~1,000 with a stop, mirroring the find cap.
- Add-caret-above/below column math (caller passes line-start offset and a
  goal column; clamps past-EOL on ragged/empty lines).

Tests (`MultiCaretModelTests.swift`): reverse-order shifting at 2–3 carets
(insert/delete/replace/mixed lengths, UTF-16 surrogate pairs), caret merge
on convergence, occurrence selection (whole-word vs substring, capped),
column math on ragged lines, normalization/clamp.

Gate: model API frozen; full test suite green; no UI change.

Execution record (2026-07-17): **MC1 complete.** Added the pure model and 15
focused tests; `swift build`, the full 520-test suite, formatter fix, and lint
are green. The frozen model includes forward/backward delete plans earlier than
the original anchor implied: empty carets expand with
`rangeOfComposedCharacterSequence` before reverse-order editing, preventing a
multi-caret delete from splitting a UTF-16 surrogate pair or grapheme cluster.

## MC2 — Caret set in the view + spikes + secondary-caret rendering

- `RafuTextView`: `private var caretRanges: [NSRange]` (authoritative);
  `applyCaretRanges(_:)` normalizes, writes `super.setSelectedRanges` for
  highlighting, updates the overlay, stores the primary. Plain user
  selection changes (via `textViewDidChangeSelection`,
  `CodeEditorView.swift:498`) collapse the set — a normal click always
  resets multi-caret.
- **Run Spikes A and B first**; choose overlay-vs-native accordingly and
  record both findings.
- Secondary carets: rects via `layoutManager.boundingRect(forGlyphRange:
  in:)` + `textContainerOrigin` (pattern at `RafuTextView.swift:349–352`),
  drawn **above** glyphs; blink honors
  `accessibilityDisplayShouldReduceMotion` (steady when on).
- v1 limitation, deliberate: suppress the current-line highlight and
  bracket box while `caretRanges.count > 1` (they key off the single
  `selectedRange()` and would mislead).

Gate: two carets render and blink; single-caret rendering untouched;
`--verify` pass.

## MC3 — Typing/delete/paste fan-out with one undo step

- Override `insertText(_:replacementRange:)`, `deleteBackward(_:)`,
  `deleteForward(_:)`, `paste(_:)`. Bail to `super` at ≤1 caret or
  `hasMarkedText()`.
- Multi-caret path: `MultiCaretModel` returns reverse-ordered sub-edits;
  one `beginUndoGrouping()`; per sub-edit `shouldChangeText` →
  `replaceCharacters` → `didChangeText()`; single
  `setActionName("Multi-Cursor Edit")` **before** `endUndoGrouping()`;
  then `applyCaretRanges(newRanges)`.
- N `recordEditDelta` calls + N serial reparse enqueues per gesture is the
  accepted contract (in-order, never dropped) — state it in the handoff.
- Known v1 limitation: delegate auto-indent (`CodeEditorView.swift:503–523`)
  doesn't fan out per caret on newline; documented, not fixed.

Gate: one ⌘Z reverts the whole batch, one ⌘⇧Z redoes it; no undo-group
exception; 200-cap respected; tree-sitter highlighting correct after batch
edits in a Swift buffer and a regex-fallback buffer.

## MC4 — Gestures and view-level commands

- `mouseDown` (:121): before the ⌘-click branch, ⌥-click (without ⌘)
  toggles a caret at the clicked character index; existing ⌘-click and
  plain-click branches intact.
- `keyDown` (:168): Esc (keyCode 53) with >1 caret →
  `collapseToPrimaryCaret()`, consumed; otherwise existing behavior.
- View methods: `selectNextOccurrence()`, `selectAllOccurrences()`,
  `addCaret(direction:)`, `collapseToPrimaryCaret()`;
  `scrollRangeToVisible` on the newest caret.
- `EditorDocument`: additive `@ObservationIgnored` closures
  (`selectNextOccurrenceAction`, `selectAllOccurrencesAction`,
  `addCaretAboveAction`, `addCaretBelowAction`) mirroring
  `toggleCommentAction` (:108); set in `makeNSView`, cleared in
  `dismantleNSView` (`CodeEditorView.swift:114–142`).

Gate: full manual gesture checklist below, except menu paths.

## MC5 — Menu commands (shared-file hunks, land LAST)

- `WorkspaceSession`: `selectNextOccurrence()` etc. mirroring
  `toggleLineComment()` (`WorkspaceSession.swift:1096`).
- `RafuAppCommands`: menu buttons — proposed ⌘D (select next occurrence),
  ⌘⇧L (select all occurrences), ⌥⌘↑/⌥⌘↓ (add caret above/below).
  **Shortcut-conflict check with the integration owner is mandatory
  first**: ⌘D vs a future duplicate-line command (Phase 2 scope), ⌥⌘↑/↓ vs
  tab/pane navigation. ⌘⇧F/⌘⇧G/⌘⇧P and ⌃`/⌃⇧` are taken
  (`RafuAppCommands.swift:58–76`).
- Coordinate with the fan-out integration owner — Git and IPC lanes also
  append commands here.

Gate: every command has a menu path (AGENTS.md visible-path rule);
keyboard reachability pass.

## MC6 — Documentation close-out

`docs/references/multi-caret-editing.md`: Spike A/B findings, the
reverse-order edit rule, undo-group naming rule, the N-delta batch
semantics, v1 limitations (IME bail, auto-indent, current-line highlight
suppression, hibernation collapse). Handoff summary for merge.

## Manual GUI checklist (MC4/MC5 gates)

- ⌥-click adds a caret; typing inserts at all carets; ⌥-click on an
  existing caret removes it; plain click collapses.
- Word + ⌘D repeatedly extends to following occurrences; ⌘⇧L selects all;
  a single edit renames all; one ⌘Z reverts everything.
- ⌥⌘↓/⌥⌘↑ over short/empty lines clamps without crash.
- Esc collapses to primary.
- IME composition with multiple carets: clean bail, no crash.
- Second window independent; hibernate/restore a multi-caret tab → single
  caret at primary, no data loss.
- Reduce Motion: steady secondary carets. Full Keyboard Access/VoiceOver:
  commands reachable via menu.

## Risks

- **Spike A failure mode** (AppKit coalesces empty ranges): overlay owns
  all secondary carets; `selectedRanges` holds only the primary — the
  authoritative view-owned set keeps correctness independent of AppKit
  retention.
- Undo fragmentation blowing the 200 cap — explicit grouping is the gate.
- Occurrence scan on huge buffers — capped (MC1).
- Shortcut collisions — resolved before MC5 lands, never after.

## Exit

- Model fully unit-tested; fan-out edits are one undo step; single-caret
  path unchanged; gestures + menu paths live; deltas/reparse in-order;
  hibernation collapses safely; spikes + nuances documented; all gates
  green.
