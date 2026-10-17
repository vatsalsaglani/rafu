# Bounded document Find work

- Applies to: `DocumentFindState`, `NSTextViewFindController`, and
  `DocumentFindSearch` in the local editor.
- Integration environment: Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.0.1
  (26A434), 2026-10-17. The integrated build and focused regression checks pass.
  Final full-suite results and UI limits are recorded in the repair handoff.
  These checks do not establish a runtime speed gain or release memory budget.

## Rule

TextKit owns live text. The Find controller observes character edits from its
own `NSTextStorage` on the main actor. It advances a local text revision and
invalidates search results and cancels work synchronously. It then schedules
one main-queue callback for highlight removal, UI metadata, text snapshot capture,
and refresh. Multiple edits before that callback share the same callback. Do not
change layout-manager temporary attributes within a storage edit notification:
TextKit can still be updating its character and layout ranges. Explicit commands
that arrive before the callback retain their request key and selection, then run
after the transaction. A changed key invalidates the deferred command. The
completion hook awaits both the queued callback and subsequent search work.
Attribute-only edits do not invalidate results. This includes programmatic text loads and native undo. The editor coordinator
can still call `DocumentFindState.refresh()`; that call does not need a new
text snapshot when the request or cached result already has the current key.

A closed Find panel does not start refresh searches or capture edit snapshots.
An explicit Find Next, Find Previous, Replace, or Replace All command can start
a search while the panel is closed. Closing the panel cancels pending work and
clears match highlights. An invalid regex is reported when an active refresh or
an explicit command searches; a retained closed query is not evaluated on edits.

Each controller permits one running search and one pending request. A newer
pending request replaces the old pending snapshot. Cancellation does not release
the running slot until its worker returns. There is no detached task per edit.
The task holds immutable `Sendable` search input and a weak controller reference.
`@concurrent` explicitly puts matching on the concurrent executor under Swift
6.2 caller-isolation rules. AppKit access, selection, undo, and UI metadata stay
on the main actor.

The cache key contains the text revision, query, and options. Replacement
commands also key their expanded match data by replacement template. Navigation
and refresh use an empty template, so changing replacement text does not force
navigation to expand captures. There is one cached result, not a snapshot history.
The complete match array remains proportional to the number of matches. The
2,000-match highlight limit only bounds temporary highlight attributes.

Before a result is used, the controller checks the request identity, attached
state, text revision, query, options, and applicable replacement template. A
current replacement also checks that selection has not changed while it waited.
Controller replacement cancels the previous owner; an old detach cannot detach
the new owner. Cancelled results never become valid empty results.

Repeated navigation commands with the same selection combine in one request.
Repeated current-replacement commands also retain a bounded integer count in
that request. After each replacement, the controller searches the new revision,
advances selection, and runs the next retained command. Each replacement has its
own native undo group. If no match was selected, the first Replace only selects
a match, as before. No list of per-command text snapshots is retained.
Navigation uses binary searches over ordered match ranges. A selected
zero-length match is skipped on the next navigation step, with wraparound. A
query or option change clears this old selection marker before navigation.
Replacement applies matches from the end and uses one native undo group. Replace
All batches storage changes into one TextKit editing transaction.

## Cancellation limit

`NSRegularExpression` has no hard deadline in this boundary. Search checks for
cancellation before work, at Foundation enumeration/progress callbacks, and after
work. A cancellation request does not guarantee that Foundation will interrupt
a single regex call promptly. A pathological regex can keep the one running
slot occupied. Stale-result checks prevent its result from changing the editor;
they do not establish a CPU-time bound. No runtime speed claim is made here.

## Evidence and checks

The source review supplied for the repair found that `refresh()` enumerated all
matches on the main actor before it checked panel activity. The 2026-10-17 runtime
baseline searched a 12,000-line fixture successfully. It did not isolate the
runtime cost of hidden Find work.

`DocumentFindAsyncRepairTests` uses search counters and continuation-controlled
workers. It covers hidden edit suppression; reopen after edits; one running and
one latest pending request; stale completion after close, detach, and controller
replacement; options; invalid regex; explicit closed-panel navigation; repeated
navigation; Unicode replacements and undo; zero-length matches; a selection
change before current replacement; active highlights through a large native
paste, full delete, and undo; multiple storage edits with one deferred search;
query and option changes after zero-length selection; and repeated Replace
commands while a matcher is blocked. The large-edit test uses a recording
`NSLayoutManager`. It compares character-edit notifications with completed
`processEditing(for:edited:range:changeInLength:invalidatedRange:)` calls, and
checks for client background-color changes before layout-manager processing
completes. It awaits actual search completion. It uses no fixed sleeps.

The Swift 6.4/macOS 27 SDK declares these `NSLayoutManager` overrides
nonisolated. The central test compile reported `sending self risks causing data
races` when an override captured the non-Sendable layout manager in
`MainActor.assumeIsolated` (repair test compile 4, 2026-10-17). The recorder now
keeps only its value counters in a `Synchronization.Mutex`, exposed through an
immutable nonisolated property. Overrides use that lock without an actor hop.
They release it before calls into AppKit so reentrant calls cannot deadlock.
The AppKit object is not declared Sendable. The ordering assertions remain.
The integrated build and focused Find tests verify this correction.

 `EditorFindTests` retains its existing behavior assertions and
awaits completion at asynchronous search boundaries. The focus-routing tests do
not assert match results and need no asynchronous adaptation.

Static checks run in the worker worktree:

```bash
swift format lint --strict Sources/RafuApp/Editor/DocumentFind.swift Sources/RafuApp/Editor/DocumentFindSearch.swift Tests/RafuAppTests/DocumentFindAsyncRepairTests.swift Tests/RafuAppTests/EditorFindTests.swift
git diff --check
```

Integration verification commands:

```bash
./script/test.sh --filter 'DocumentFindAsyncRepairTests|textSearchModes|textViewFindBridgeSupportsUndo|matchHighlightsFollowActivation|invalidRegexIsNonDestructive|EditorFindFocusRoutingTests'
./script/build.sh
./script/test.sh
./script/test.sh --no-parallel
```

Run these only within the coordinator's machine build slot. Use the canonical Rafu Lightning app script for app checks. Comparable runtime
performance measurements remain pending. Check two-window
state, keyboard Find/Replace, undo, edits with Find closed, and reopen.

## Related material

- `Sources/RafuApp/Editor/DocumentFind.swift`
- `Sources/RafuApp/Editor/DocumentFindSearch.swift`
- `Tests/RafuAppTests/DocumentFindAsyncRepairTests.swift`
- `Tests/RafuAppTests/EditorFindTests.swift`
- `Tests/RafuAppTests/EditorFindFocusRoutingTests.swift`
- [ADR 0006](../decisions/0006-editor-working-set-hibernation.md)
- [Workbench phase](../plans/phases/pre-initial-push-workbench.md)
- [Writing Tools layout limit](macos26-writing-tools-textkit-layout.md)
- [Swift isolation note](nonisolated-extension-isolation-trap.md)

The coordinator must add this note to the shared reference index at integration.
