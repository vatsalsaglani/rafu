# Post-merge validation fixes — execution plan

## Status

Planned. Produced by the coordinator's personal post-merge validation of the
merged lane-1 + lane-2 tree (2026-07-15; baseline: build clean, 451/451
tests, format lint clean, app-launch --verify green). Nine findings, ordered
by severity, grouped into batches A–E below. Each batch is one advisor →
implementor → verification → documentor cycle. File paths and line anchors
reflect the tree at validation time; the advisor re-verifies each at brief
time and the brief wins where they disagree.

## Global rules

- The two-lane path split is over: all paths are editable. The increment-0
  navigation contract types may take **additive** changes only where a batch
  explicitly allows it; no reshaping of existing fields.
- Pinned tests must stay green untouched: `SearchCommandPaletteTests`
  (`CommandPaletteMatcher.rank`/`score`/`rankFiles`, `PaletteQueryParser`
  modes), plus the whole 451-test baseline.
- No `@unchecked Sendable`. Swift 6.2 strict concurrency; tree-sitter's
  non-`Sendable` types never cross an `await`.
- Verification per batch: `swift build`; `swift test`;
  `./script/format.sh --fix` then `--lint`; and
  `./script/build_and_run.sh --verify` whenever UI/scene behavior changed.
- Never log document text, server payloads, or secrets.
- Explicitly OUT OF SCOPE for this pass (do not attempt): Release-build
  latency/RSS measurements, Instruments signpost reads, live GUI/VoiceOver
  passes (manual, coordinator/user-run); wiring markdownInline injections
  (a deferred feature, not a defect).

---

## Batch A — user-facing correctness (findings 1–3)

**Status: COMPLETE 2026-07-15** — All three user-facing correctness fixes verified; build clean, tests green, app-launch --verify passed.

### A1 (BLOCKER). Mount the language-server trust prompt

**Status: COMPLETE 2026-07-15.**

**Problem.** `InstalledServerResolver.resolve` hard-gates every server on
`isTrusted` (Registry/InstalledServerResolver.swift:67). The only writer of
trust is `LanguageIntelligenceCoordinator.approveTrust(_:)`, and nothing in
the UI presents `LanguageServerTrustPromptView` or calls
`approveTrust`/`declineTrust` — `pendingTrustRequest` is observed by no
view. Result: even after installing a server from the catalog, every
navigation declines at the LSP tier forever; Stage C is unreachable by a
real user.

**Fix (precise).**
- In `Sources/RafuApp/Views/WorkspaceWindowView.swift`, present the existing
  `Sources/RafuApp/LanguageIntelligence/Trust/LanguageServerTrustPromptView`
  as a sheet driven by `session.languageIntelligence.pendingTrustRequest`
  (use `.sheet(item:)` if `TrustRequest` is `Identifiable`, else derive an
  `isPresented` binding — advisor confirms the view's init and `TrustRequest`
  shape), wiring its actions to
  `session.languageIntelligence.approveTrust(_:)` /
  `declineTrust(_:)`.
- After approval, the pending navigation is NOT automatically retried
  (acceptable: the user re-invokes Go to Definition). If the advisor finds a
  clean ≤5-line retry hook, allowed but optional.
- Accessibility: the sheet needs VoiceOver labels and a keyboard path
  (default/cancel key equivalents).

**Tests/acceptance.** Build/tests green; manual acceptance recorded as owed
(needs a live server). A unit test that `approveTrust` + resolver-snapshot
rebuild makes `session(forLanguageID:)` succeed already exists in lane-2's
trust-flow tests — do not duplicate; the new work is UI-only.

### A2 (HIGH). `SyntacticNavigationProvider` must treat `.idle` as indexing

**Status: COMPLETE 2026-07-15.**

**Problem.** `Sources/RafuApp/Navigation/SyntacticNavigationProvider.swift`
maps only `currentState == .building` to `state: .indexing`. For `.idle`
(cold start, or after `respondToMemoryPressure()` sheds the index) it runs
`lookup()` on an empty index and returns a non-nil authoritative-empty
`.ready` — which wins the ladder and blocks the text tier, showing "No
definition found". `navigate()`'s `ensureSymbolIndexReady()` flips the
session-side state synchronously but the actor's state flips only when
`build()` starts executing, so the ladder can observe `.idle`.

**Fix (precise).** In `answer(_:)`, change the state check to treat both
`.building` and `.idle` as `.indexing` (an index that has never been built
is never an authoritative "no"):
`if await index.currentState is .building or .idle → return
NavigationAnswer(tier: .syntactic, candidates: [], state: .indexing)`.

**Tests.** Add a `SyntacticNavigationProviderTests` case: a fresh
(never-built) index + a definition request ⇒ answer state `.indexing`,
not an empty `.ready`.

### A3 (HIGH). `didOpen` must not carry empty text for a just-opened document

**Status: COMPLETE 2026-07-15.**

**Problem.** `LanguageIntelligenceCoordinator.documentDidOpen` runs
synchronously inside `WorkspaceSession.trackNewDocument`, before the editor
mounts, so `document.textSnapshotProvider` is `nil` and `didOpen` is sent
with `""` (LanguageIntelligenceCoordinator.swift:266). The session's
mirror-fallback self-heals on the first keystroke, and lazy server start
replays live text — but against an **already-running** server, opening a
file and immediately invoking Go to Definition (no edit) yields an
authoritative-empty LSP answer that blocks the syntactic tier.

**Fix (precise).** In `documentDidOpen`, when `textSnapshotProvider` is
`nil`, read the document's text from disk as the `didOpen` payload — the
document was just opened clean, so disk is the truth. Do the read off the
main actor inside the existing `Task` that calls `manager.documentOpened`
(e.g. `Task.detached` or the `WorkspaceFileService.readText` pattern;
respect its 4 MB cap — an oversized/unreadable file falls back to `""` as
today). When the provider IS available, behavior is unchanged.

**Tests.** A coordinator test: open a document whose provider is nil with a
real temp file on disk ⇒ the manager receives the disk text (assert via the
existing in-memory transport / manager test seams).

---

## Batch B — visibility and typing-path cost (findings 5, 4)

**Status: COMPLETE 2026-07-15** — Server status surface and edit-forwarding gate verified; build clean, tests green, app-launch --verify passed.

### B1 (MEDIUM). Surface server status + restart (make "kill + notify" real)

**Status: COMPLETE 2026-07-15.**

**Problem.** ADR 0005 requires the RSS-ceiling watchdog to kill AND notify,
offering restart. The manager kills and publishes to
`LanguageServerStatusStore`, but no view reads it; the catalog rows show
install-state only; a killed/crashed server disappears silently and
navigation quietly degrades.

**Fix (precise).**
- Add a "Language Servers" section to
  `Sources/RafuApp/Views/ResourcesView.swift` listing
  `session.languageIntelligence.servers.statuses` (language, display name,
  state label; advisor verifies the `LanguageServerStatus` field names) with
  a Restart button per crashed/killed row calling a coordinator passthrough
  to the manager's existing manual-restart API (add a thin
  `LanguageIntelligenceCoordinator.restartServer(languageID:)` if absent).
- Plumbing: `ResourcesView` currently takes no session — pass the session
  (or just the coordinator) down from `WorkspaceStatusBar`'s popover call
  site (`WorkspaceStatusBar` is constructed in `WorkspaceWindowView`, which
  has the session).
- State must not be conveyed by color alone; rows need VoiceOver labels.

**Tests.** Status-store rendering logic that is pure (state → label) gets a
small test; the passthrough gets a coordinator test if a seam exists.

### B2 (MEDIUM). Stop copying the whole document per keystroke when no server is live

**Status: COMPLETE 2026-07-15.**

**Problem.** `documentDidOpen`'s edit-subscription task (MainActor-inherited)
copies the entire document via `textSnapshotProvider()` and hops to the
manager on every keystroke for every LSP-recognized language — where
`documentChanged` drops it (`guard servers[languageID] != nil`). Combined
with the syntax pipeline's own per-keystroke snapshot (a documented 8b
tradeoff), that is two full-buffer copies per keystroke, one pure waste
unless a server is running.

**Fix (precise).** Gate the copy on a live server before snapshotting:
inside the `for await delta in document.editDeltas()` loop, consult the
main-actor `servers.statuses[languageID]` (the loop is MainActor-isolated;
the store is `@MainActor @Observable`) and `continue` unless the status
represents an active/starting server (advisor verifies the status enum and
picks the correct case set). Correctness is preserved because
`LanguageServerManager` replays all open documents via `snapshotProvider`
when a server starts — deltas skipped while no server exists are never
needed.

**Tests.** Coordinator test: with no server status present, a delta does NOT
reach the manager (assert via a counting manager/test seam); with a
ready status present, it does.

---

## Batch C — consolidation (finding 6)

**Status: COMPLETE 2026-07-15** — Canonical LanguageCatalog and cross-consistency verification complete; byte-identical wrapper behavior verified against current code; build clean, tests green.

### C1 (MEDIUM). One canonical language-mapping table

**Status: COMPLETE 2026-07-15.**

**Problem.** Four parallel mappings drift: `LanguageIdentifier.forURL`
(LSP ids), `GrammarLanguageID.languageID(forExtension:fileName:)`,
`GrammarLanguageID.languageID(forInfoString:)`, and `SyntaxHighlighter`'s
regex extension groups. This already bit once (`.tsx` → "tsx" vs
"typescriptreact", fixed at integration).

**Fix (precise).** Introduce one canonical, pure, `nonisolated` table (e.g.
`Sources/RafuApp/Editor/Syntax/LanguageCatalog.swift`): rows keyed by
extensions/special filenames/fence info-strings mapping to
`(grammarID: GrammarLanguageID?, lspID: String?)`. Refactor
`LanguageIdentifier.forURL`, both `GrammarLanguageID.languageID(...)`
functions, and (where practical without touching regex behavior) the
highlighter's language detection to delegate to it, keeping every existing
public entry point as a thin wrapper so all call sites and pinned tests are
untouched. Behavior must be byte-identical: write a cross-consistency test
FIRST (for every known extension, the wrapper outputs equal the current
outputs) and keep it.

**Tests.** The cross-consistency test plus the existing GrammarRegistry /
LanguageIdentifier tests stay green unmodified.

---

## Batch D — polish (findings 7, 8, 9a, 9b)

**Status: COMPLETE 2026-07-15** — Trust settings, navigation disclosure, buffer symbols unification, and ⌘-click all verified; build clean, tests green, app-launch --verify passed.

### D1 (LOW). Trust management in Settings

**Status: COMPLETE 2026-07-15.**

`WorkspaceTrustStore` persists approvals but the Language Servers pane
offers no way to see or revoke them (ADR 0005: a decline lasts "until the
user changes it in Settings" — that surface doesn't exist). Add a
"Workspace Trust" section to
`Sources/RafuApp/Settings/LanguageServersSettingsSection.swift` listing
approvals from `WorkspaceTrustStore.load()` (workspace path → server ids)
with per-row Revoke; add a `revoke(serverID:forWorkspaceKey:)` (atomic
write, mirroring `approve`) to the store if absent. Note in the UI that a
running server keeps running until the workspace reopens or it idles out
(do not build live-revocation teardown in this pass; document it).

### D2 (LOW). Rank + disclose the text-tier references list

**Status: COMPLETE 2026-07-15.**

`TextSearchNavigationProvider` answers references unranked and silently
capped. (a) Rank its candidates same-file → same-directory → path order,
reusing/extracting the comparator from `SyntacticNavigationProvider.rank`
into a shared pure helper. (b) In `NavigationPeekView`, when
`candidates.count` equals the text tier's result cap (expose the cap as a
named constant on the provider), show a footer "Showing first N matches."
No `NavigationAnswer` shape change in this pass.

### D3 (LOW). Unify buffer-symbol extraction with the workspace extractor

**Status: COMPLETE 2026-07-15.**

`BufferSymbolScanner.scanUsingGrammar` still has the duplicate-Swift-method
wart and drops property/constant kinds (both already solved in
`WorkspaceSymbolExtractor`). Delegate the `@`-mode grammar path to
`WorkspaceSymbolExtractor.extract` and map its kinds:
function/method → `.function`; class/interface → `.type`; property →
new `BufferSymbol.Kind.property`; constant → new `.constant`; module →
skip. Add SF Symbols + labels for the two new kinds in the palette's
symbol rows. Update the test that currently documents the duplicate wart to
assert deduplication instead; add property/constant fixture assertions.
Keep the 2,000 cap and regex fallback untouched.

### D4 (LOW). Deliver the deferred ⌘-click

**Status: COMPLETE 2026-07-15.**

Implement exactly the recorded approach: override
`RafuTextView.mouseDown(with:)`; when
`event.modifierFlags.contains(.command)`, convert the point
(`convert(_:from: nil)`), get the caret via
`characterIndexForInsertion(for:)`, `setSelectedRange` to that caret, and
invoke a new plumbed closure (pattern: `saveAction`) that calls
`session.navigate(kind: .definition)`; otherwise call `super`. Set/clear
the closure in `CodeEditorView.makeNSView`/`dismantleNSView`. Plain clicks,
drags, and text selection must be untouched (command-flag check first,
`super` for everything else).

---

## Batch E — documentation close-out (finding 9 remainder)

Documentor-only batch, after A–D verify:

- Record in `docs/references/` (navigation/workspace-symbol-index/LSP notes
  as fitting): the trust-prompt mount, idle-as-indexing semantics, the
  disk-fallback `didOpen`, the live-server gate on edit forwarding, the
  status/restart surface, the canonical `LanguageCatalog`, trust revocation,
  reference ranking/disclosure, unified buffer symbols (+ new kinds),
  ⌘-click.
- Record two deliberate decisions: hibernated documents intentionally stay
  LSP-open (no `didClose` on hibernation; bounded by the RSS ceiling), and
  markdownInline injections remain deferred (feature, not defect).
- Mark each finding's status in THIS file and add a completion line to
  `docs/plans/phases/lane-1-memory-and-syntax-plan.md`'s Exit section
  ("post-merge validation fixes complete").
- Still-owed manual items (unchanged): Release-build typing p95 + idle RSS,
  Instruments signpost read, live GUI/VoiceOver/second-window passes, live
  LSP round-trip with a real server.

## Exit

**All batches A–E COMPLETE 2026-07-15.** All 9 findings (A1–A3, B1–B2, C1, D1–D4) implemented, verified, and documented.

Verification summary:
- Build: clean (no warnings)
- Tests: 451 → 453 (A) → 461 (B) → 471 (C) → 485 (D), all passing
- Format lint: clean
- App-launch: green for UI batches (A, B, D)
- Pre-existing flaky tests noted (LanguageServerManagerTests crash-escalation "becameDead", LanguageServersCatalogModelTests install-progression "progressWhileInstalling") — timing-sensitive under parallelism, not introduced by this pass

Documentation:
- Batch E reference notes updated in docs/references/ (navigation-and-lsp-contracts.md, workspace-symbol-index.md, tree-sitter-highlighting.md, editor-working-set-and-hibernation.md, memory-caps-and-pressure.md)
- Two deliberate decisions recorded: (a) hibernated documents stay LSP-open (no didClose on hibernation), (b) markdownInline injections deferred (feature, not defect)
- Findings status marked in this file; completion line added to lane-1-memory-and-syntax-plan.md Exit section

Manual items OWED (coordinator/user-run):
1. Release-build typing p95 + idle RSS measurement
2. Interactive Instruments signpost read (mode=incremental)
3. Live GUI/VoiceOver/second-window passes for: trust prompt sheet, Resources server section, palette property/constant rows, ⌘-click
4. Live LSP round-trip with a real installed server (end-to-end path A1 unblocks)

---

## Post-fix increment — Crash fix and navigation features (2026-07-16)

**Status: COMPLETE 2026-07-16** — Crash fix and three navigation features verified; build clean, tests 489/489 passing (485 baseline + 4 new), format lint clean, app-launch --verify green. Advisor final review of navigation features: ALL 8 correctness areas CONFIRMED-SAFE (hover debounce race, retain cycles/leaks, tooltip dismissal, references fall-through, hoverInfo side-effect-freeness, menu, concurrency/isolation, no payload logging). One optional teardown hardening (performClose→close) applied; no defects.

### F1. Crash fix: MemoryPressureMonitor GCD isolation

**Status: COMPLETE 2026-07-16.**

A closure passed to `DispatchSource.setEventHandler` under the RafuApp target's `.defaultIsolation(MainActor.self)` is inferred `@MainActor`-isolated by the compiler, but DispatchSource invokes it on a private serial queue, not the main actor. Swift 6's executor check kills the process with `EXC_BREAKPOINT (SIGTRAP)` the moment a real memory-pressure event fires.

**Fix:** Mark the handler `@Sendable` (non-isolated) and hop to the main actor internally. Verified: MemoryPressureMonitor was the only DispatchSource in the codebase.

**Durable rule documented:** default-MainActor + GCD/DispatchSource off-main handler must be `@Sendable`/non-isolated + hop internally. Contrast: NotificationCenter(queue:.main) does run on main thread, so MainActor.assumeIsolated is safe there. Recorded in `docs/references/concurrency.md`.

### F2. Hover tooltip

**Status: COMPLETE 2026-07-16.**

Mouse-hover over an identifier resolves LSP hover through the navigation ladder (LSP tier only; syntactic and text decline `.hover`) and displays a bounded, scrollable, monospaced `.semitransient` NSPopover with server signature/docstring + "Go to Declaration" button. 450 ms cancellable-Task debounce (no timer). Tooltip dismisses on edit, scroll, keyDown, Escape, outside-click; mouseExited cancels only pending resolve. `WorkspaceSession.hoverInfo(at:utf16Offset:)` is offset-explicit and side-effect-free. Reduce Motion: `popover.animates = false`.

### F3. References graceful fallback

**Status: COMPLETE 2026-07-16.**

`LSPNavigationProvider.locationAnswer` declines (returns nil) on empty `.references` candidates, allowing the ladder to fall through to text tier. `.definition`/`.declaration` stay authoritative-empty. `TextSearchNavigationProvider` also declines `.hover`. True cross-file references require enabling sourcekit-lsp's index store via `ServerDescriptor.initializationOptions` in the LSP `initialize` handshake (curated sourceKitLSP descriptor currently sets it nil); this is the real follow-up for true references — the fall-through is the pragmatic interim.

### F4. Context menu and navigation plumbing

**Status: COMPLETE 2026-07-16.**

`RafuTextView.menu(for:)` augments default copy/paste/lookup menu with "Go to Definition" (⌃⌘J), "Go to Declaration", "Find References" (⌃⌘R) at top, gated on wired `navigateAction` and an identifier at the click. `RafuTextView.goToDefinitionAction` generalized to `navigateAction: (NavigationTargetKind) -> Void`. Separate `hoverAction: (Int) async -> EditorHoverInfo?` handles hover. Both set in `CodeEditorView.makeNSView`, cleared in `dismantleNSView`, threaded through `EditorGroupView` + `MarkdownEditorPresentation` so both code and markdown editors get all features. `EditorHoverInfo` (Sendable) + `EditorHoverTooltipView` new types.

### Exit (updated)

All batches A–E PLUS post-fix increment F complete. Verification:
- Build: clean
- Tests: 485 (post-merge baseline) → 489 (post-fix +4 new)
- Format lint: clean
- App-launch --verify: green

**Remaining manual items** (documented in this file's top section, unchanged):
1. Release-build typing p95 + idle RSS (noted in lane-1 8b/plan §7.5)
2. Instruments signpost read (mode=incremental)
3. Live GUI/VoiceOver/second-window for: trust prompt, Resources servers, palette property/constant rows, context menu/tooltip
4. Live LSP round-trip with installed server
5. sourcekit-lsp index-store initializationOptions work for true cross-file references (the real follow-up to F3)
