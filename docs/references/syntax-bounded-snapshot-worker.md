# Bounded syntax snapshot work

- Applies to: `NeonSyntaxHighlightingPipeline`, `SyntaxSnapshotWorker`,
  `SyntaxParsingActor`, and `SyntaxByteOffset.LineIndex`.
- Integration environment: Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.0.1
  (26A434), 2026-10-17. The integrated build and focused regression checks pass.
  Final full-suite results and UI limits are recorded in the repair handoff.
  These checks do not establish a runtime speed gain or release memory budget.

## Rule

One editor has one syntax worker. The worker runs one parser operation and keeps
at most one pending snapshot. A new edit replaces pending work. When this occurs,
the pending request becomes a full snapshot reset. It must not retain an edit
relative to a text version that the parser did not receive.

The worker sends contiguous edits in order. The parser also checks the version:
older edits are rejected, and a version gap requires a full parse. Tree edit and
parse run on the parser actor with no suspension between them. Parser and tree
objects do not cross the actor boundary.

Token requests require the exact parser version. After the query returns, the
pipeline checks actor identity, content generation, snapshot version, suppression,
and teardown state. A stale or cancelled request completes with failure. It must
not complete with an empty success or `.noChange`: Neon treats successful ranges
as valid even when their offsets belong to the old document. Undo can then fail
in Neon's range transformation.

The pipeline forwards every text edit to Neon's range bookkeeping, including
edits made while syntax is suppressed. Suppression stops parsing and queries.
Teardown is final for that pipeline instance. It clears pending snapshots,
cancels activation, parser work, and the current token task, and removes scroll
observers. A running parse checks cancellation at read callbacks and discards
its result if cancelled. This is cooperative cancellation; it is not a hard
latency guarantee for code running inside tree-sitter between callbacks.

Full highlight invalidation remains after the newest parse. A change to a
multiline comment or string can affect tokens beyond the edited line. Intermediate
parse completions do not invalidate the editor.

## Indexed positions and cache limits

The parser keeps LF line starts for the exact snapshot version. Point lookup
uses binary search. An edit scans only replacement UTF-16 units, then shifts the
remaining line starts. It does not scan the document prefix three times. The
suffix shift is still proportional to the number of later lines.

Tree-sitter's UTF-16 path counts LF as a row break. CR remains a byte-column unit,
including in CRLF. Surrogate pairs take two UTF-16 units. Points can refer to the
middle of a pair; byte columns still use UTF-16 units times two. The index and
retained text are dropped when the document exceeds the existing 2,000,000-unit
parse cap.

Compiled fallback expressions, the editor font, and resolved token attributes
are cached within one immutable highlighter configuration. A changed theme or
language replaces that configuration. Theme comparison checks actual style
values, so a changed theme with the same name is not ignored. There is no global
cache of user theme versions or document text.

The main actor still captures a full text snapshot for each edit. The queue
bounds retained pending work; it does not remove that capture cost. No typing
latency or memory improvement is claimed without a comparable runtime trace.

## Evidence and reproduction

The former task chain retained one full snapshot per task and cancelled only its
tail. The new worker has one pending slot and no predecessor task references.
The `snapshotQueue` signpost in subsystem `dev.vatsalsaglani.rafu`, category
`syntax`, records pending count, active count, combined-edit count, and full reset
count. It records no text, token contents, paths, or credentials.

`SyntaxSnapshotRepairTests.swift` adds a signal-controlled slow operation. The
tests submit 99 edits during one active operation, check the one-slot bound,
check the full reset, and compare the final and undone spans with fresh parses.
Other tests cover cancellation, worker release during a suspended operation,
stale and missing versions, Unicode and multiline incremental parse equivalence,
UTF-16 point boundaries, replacement-only scan counts, suppression, teardown,
real multi-caret undo, current token application after syntax is re-enabled,
and regex repaint through `CodeEditorView.Coordinator.syncGuardSuppression`,
plus fallback cache results. All 11 focused syntax repair tests pass in the
integration checkout. Worker worktrees did not run SwiftPM.

## Verification commands

Run these commands in the integration checkout after the coordinator grants the
machine build slot:

```bash
./script/test.sh --filter syntaxRepair
./script/test.sh --filter 'syntaxActor|byteOffset|pointMaps|pointHandles|pointClamps|pointOnEmpty|inputEditOffsets|multiCaretUndoSurvivesStaleTokenRequest'
./script/build.sh
./script/test.sh
./script/test.sh --no-parallel
```

The coordinator must also use the canonical Rafu Lightning app check and compare
syntax parse/query/apply and `snapshotQueue` signposts during fast edits, large
multiline edits, undo, suppression, and editor teardown. The worker did not launch
or stop an app.

## Related code and decisions

- `Sources/RafuApp/Editor/SyntaxHighlighter.swift`
- `Sources/RafuApp/Editor/Syntax/SyntaxSnapshotWorker.swift`
- `Sources/RafuApp/Editor/Syntax/SyntaxParsingActor.swift`
- `Sources/RafuApp/Editor/Syntax/SyntaxByteOffset.swift`
- `Sources/RafuApp/Editor/Syntax/SyntaxSignpost.swift`
- `Tests/RafuAppTests/SyntaxSnapshotRepairTests.swift`
- ADR 0005, bounded language intelligence.
- `docs/plans/phases/pre-initial-push-workbench.md`, acceptance item 15.
- `docs/plans/phases/editor-performance-repair.md`, syntax ownership.

This note replaces the task-chain and version-tag guidance in the incremental
parsing section of `tree-sitter-highlighting.md`. The coordinator owns the shared
reference index and the update to that older note.
