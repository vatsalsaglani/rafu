# Navigation ladder and LSP client contracts

- **Applies to:** navigation types and providers, document edit deltas, the
  Language Intelligence subsystem seam, and process resource registration
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-16

## Rules and observed behavior

### Navigation tier contracts (lane 1–2 boundary)

The three-tier navigation ladder resolves requests by degrading gracefully.
The request shape itself encodes the tier boundaries:

- `NavigationRequest.symbolName: String?` exists because text and syntactic
  tiers resolve by identifier name only, while the LSP tier resolves by
  position and does not use the name. Syntactic and text tier providers check
  the symbol name first; LSP ignores it. This shape prevents the LSP provider
  from mistakenly using an identifier intended for earlier tiers, and allows
  fallthrough when LSP lacks a capability.
- `NavigationRequest.position` is a single `Int` UTF-16 byte offset from
  document start, matching TextKit's native `NSRange.location` representation.
  Lane 2's LSP client must not receive offsets; it mirrors the document text
  via the delta stream (`EditorDocument.editDeltas()`) and converts the
  offset to `line`/`character` format internally when issuing LSP requests.
  The conversion happens in the LSP tier provider, not the request producer.

### Document edit deltas and revision semantics

`DocumentEditDelta` is a distinct monotonic counter for every keystroke and
buffer edit, separate from `EditorDocument.revision`:

- `EditorDocument.revision` increments only on save (in `CodeEditorView`'s
  `saveDocument` path) and on external reload (in `WorkspaceSession` when
  the file changes on disk). It is **never** incremented per keystroke.
  `MarkdownPreviewView` and other consumers that call `reloadIfNeeded` key
  off `revision` — bumping it on every edit would incorrectly trigger
  constant preview reloads and break the user's scroll position. The stable
  save-point identity is the point of `revision`.
- The true per-mutation hook is `CodeEditorView.Coordinator`'s
  `textStorage(_:didProcessEditing:range:changeInLength:)` callback, gated
  on `!isLoading` to exclude external content arrival. This is where
  `EditorDocument` publishes a fresh `DocumentEditDelta` for each edit:
  - `delta.range`: `NSRange(location: editedRange.location, length: editedRange.length - changeInLength)` — the **pre-edit** range being replaced
  - `delta.replacementLength`: `editedRange.length` — the **post-edit** byte count
  - `delta.editVersion`: a monotonic counter dedicated to this emission
- Lane 2's LSP client and the syntax parser both consume `editDeltas()` and
  track `editVersion` to discard stale results from in-flight earlier edits.

### AsyncStream single-consumer semantics

`EditorDocument.editDeltas()` returns a new `AsyncStream` per caller:

- `AsyncStream` is single-consumer by design; multiple subscribers would
  silently drop values for all but the first. `EditorDocument` therefore
  mints a new stream per `editDeltas()` call and manages continuations in a
  registry keyed by `UUID`.
- The stream's `onTermination` closure runs off the MainActor (in whatever
  context calls `deinit`); updating the continuation registry is a
  `@MainActor` mutation. If termination happens off-main (e.g., a task
  cancellation from a concurrent context), the closure must hop back onto
  the main actor with `Task { @MainActor in registry.removeValue(...) }`
  before mutating the registry.
- This is a concurrency hazard: the registry itself is `@MainActor`, but the
  termination closure runs in an unspecified actor context and must transition
  explicitly.

### Process resource sampling without shelling

`ProcessResourceRegistry` samples resident memory per child process using
Darwin's `proc_pid_rusage` family, not subprocess invocation:

- `import Darwin` provides `proc_pid_rusage(_:_:_:_:)`, taking a process ID
  and a `rusage_info` version constant. Use `rusage_info_v2` and the
  `RUSAGE_INFO_V2` constant; the resident set size is in `ri_resident_size`.
- A pid that has been reaped (child process exited and was waited on)
  returns nonzero from `proc_pid_rusage`. `ProcessResourceRegistry.sample()`
  reports `residentBytes: nil` for that row rather than removing the row;
  the registry keeps rows for dead processes so the UI can show recent
  terminations without losing context.
- This avoids spawning `ps` or other tools for every sample and keeps
  sampling off the main actor.
- **Verified measurement (lane 1, increment 1, 2026-07-15):** for a running
  Rafu app process, `proc_pid_rusage` `ri_resident_size` = `ps -o rss=` to
  byte-exact accuracy (ratio 1.000). Sample method: app at idle with one
  terminal shell registered; `ProcessResourceRegistry.sample()` called via
  the Resources surface popover (sample-while-visible pattern: a `.task` loop
  that sleeps 2 seconds per iteration and exits on `Task.isCancelled`, no
  standing timers). This confirms the registry's Darwin-based measurement is
  honest against the system `ps` output and can be trusted for memory budgeting.

### Language server status surface and restart affordance (post-merge validation fix B1, 2026-07-15)

ADR 0005 requires the RSS-ceiling watchdog to kill servers AND notify the user, offering restart. `ResourcesView` now displays a "Language Servers" section listing per-server status from `session.languageIntelligence.servers.statuses`. Each server row shows language, display name, and a pure `LanguageServerStatusPresentation` (stateLabel text, showsRestart button, SF Symbol icon) — state is never conveyed by color alone (accessible to VoiceOver). A Restart button calls a thin `LanguageIntelligenceCoordinator.restartServer(languageID:)` passthrough, which clears the stale status row (new `LanguageServerStatusStore.remove`), then restarts + eager `ensureSession` for observable feedback. The plumbing chain is: `WorkspaceWindowView` → `WorkspaceStatusBar` → `ResourcesView`, with the session (or coordinator) passed down from the window.

### ProcessResourceRegistry.shared — canonical cross-lane process registry

Both lane 1 and lane 2 must use the same `ProcessResourceRegistry.shared`
singleton instance to register and unregister child process IDs:

- This is the **only** canonical source of truth for process-level resource
  tracking. Do not create a second registry or duplicate process-tracking state
  in lane 2.
- Lane 1 registers terminal shell pids (`kind: .terminalShell`) when
  `WorkspaceTerminalController` spawns a shell (guarded on
  `shellPid != 0` via SwiftTerm's `view.process.shellPid`) and unregisters
  on shell shutdown.
- Lane 2 registers language-server pids (`kind: .languageServer`) when
  spawning servers and unregisters when servers exit or are terminated.
- Git subprocesses are **deliberately not registered** because they are
  short-lived batch operations; this is an intentional non-action, not an
  oversight. It reduces registration churn and keeps the Resources surface
  focused on long-lived services.
- The single `Resources` surface (lane 1's `ResourcesView`) displays all
  registered processes from `ProcessResourceRegistry.shared.sample()`, so
  both lanes' processes are visible in one place without duplication or
  synchronization overhead.

### Swift format lint enforcer: synthesized initializer rule

The repository uses `swift format lint --strict`, which enforces the
`UseSynthesizedInitializer` rule:

- An explicit `init` method that is identical to the synthesized memberwise
  initializer (same parameters in the same order, only `self.x = x` assignments,
  no defaults or preprocessing) is a lint failure. Delete it and let Swift
  synthesize it.
- Initializers that add defaults (`init(x: Int = 0)`) or modify parameters
  before assignment are fine; the rule only flags the redundant case.
- This applies to all value types (`struct`, not `class`). The linter catches
  this automatically in the CI format check.

### Trust prompt mount and language-server lifecycle (post-merge validation fix A1, 2026-07-15)

The language-server trust gate must be presented to the user to be meaningful. When a language server is installed, `LanguageIntelligenceCoordinator.pendingTrustRequest` is published as an observable state. `WorkspaceWindowView` presents `LanguageServerTrustPromptView` as a `.sheet(item:)` driven by this state, wiring user actions to `approveTrust(_:)` / `declineTrust(_:)` callbacks. After approval, the pending navigation is NOT automatically retried (the user re-invokes Go to Definition); this deferred-retry approach avoids complexity in the request flow without a loss of functionality. The sheet supports VoiceOver labels and keyboard paths (Escape dismisses as decline; default/cancel key equivalents follow standard sheet conventions).

### SyntacticNavigationProvider idle-state handling (post-merge validation fix A2, 2026-07-15)

`SyntacticNavigationProvider.answer(_:)` must treat BOTH `.building` and `.idle` index states as `.indexing`. An index that is `.idle` (cold start, or after memory pressure sheds it) has never been built and is not an authoritative "no match" — awaiting the build is the correct response. Previously only `.building` was treated as indexing, causing `.idle` to return an authoritative-empty answer that blocked the text tier.

### DocumentDidOpen disk-read fallback (post-merge validation fix A3, 2026-07-15)

When `LanguageIntelligenceCoordinator.documentDidOpen` runs synchronously before the editor mounts, `document.textSnapshotProvider` is `nil`. Rather than send an empty `didOpen` payload to the language server (which would cause an authoritative-empty LSP answer to block syntactic fallback on immediate Go to Definition), the coordinator now reads the document text from disk off-main (respecting the 4 MB cap; oversized/unreadable files fall back to `""`). The disk read is the truth because the document was just opened clean. When the provider IS available (editor mounted), behavior is unchanged.

### Edit-forwarding gate and LanguageServerStatus.forwardsDocumentChanges (post-merge validation fix B2, 2026-07-15)

Per-keystroke edit-delta forwarding to the language server must not proceed without a live server. `documentDidOpen`'s edit-subscription task now gates the full-document snapshot on `LanguageServerStatus.forwardsDocumentChanges(phase:)` — a pure method that returns `true` only for `.starting`, `.ready`, and `.warmingUp` states, skipping `.idle`, `.backingOff`, `.dead`, `.ceilingKilled`, and `nil`. This eliminates a wasted full-document copy and actor hop per keystroke when no server is active. **Residual race (documented):** an extraordinarily narrow race for `.incremental-sync` servers could momentarily desync the server's view of a document if an edit arrives between `.starting` state publication and the first keystroke, healing on the next `.full` fallback. A zero-window `await manager.hasLiveServer(languageID:)` check is the documented alternative if ever needed.

### Hover tooltip: LSP-only, debounced, side-effect-free (post-fix increment, 2026-07-16)

Mouse-hover over an identifier resolves LSP hover through the navigation ladder (LSP tier only; syntactic and text tiers decline `.hover`) and shows a bounded, scrollable, monospaced `.semitransient` NSPopover with the server's signature/docstring + a "Go to Declaration" button. New `WorkspaceSession.hoverInfo(at:utf16Offset:)` is offset-explicit (the mouse point, not the caret) and side-effect-free, reusing an extracted `resolveLanguageID(for:)` helper.

**Debounce:** A 450 ms cancellable `Task`-based debounce (no timer) fires only if the mouse stays over the same identifier long enough. Moving the mouse to a different identifier or leaving the hover area cancels the pending resolve.

**Tooltip lifecycle:** dismisses on text edit (via `Coordinator.textStorage editedCharacters` callback), scroll (clip-view `boundsDidChange` observer on the main queue), keyDown, Escape, or outside-click. `mouseExited` only cancels a **pending** resolve; if a tooltip is already shown, the pointer can reach the "Go to Declaration" button. `dismantleNSView` tears everything down: `close()` the popover, cancel the task, remove the observer.

**Reduce Motion:** `popover.animates = false` when accessibility setting is active.

**Hover text:** uses a new `flattenedHoverMultiline` (bounded 2000 chars, preserving line structure) for `.hover` only; the existing `flattenedHover`/240 char single-line path stays unchanged for other navigation purposes.

**Side effects:** hover never moves the caret, never indexes, never modifies selection; it is a read-only lookup operation.

Hover text and tooltip rendering use new `EditorHoverInfo` (Sendable) and `EditorHoverTooltipView` types.

### References fall-through on empty candidates (post-fix increment, 2026-07-16)

`LSPNavigationProvider.locationAnswer` now **declines** (returns `nil`) when a `.references` query yields an empty candidate list or all-unreadable targets, allowing the navigation ladder to fall through to the syntactic tier (which also declines `.references`), then to the bounded text tier. This graceful degradation shows textual ("text match") results as the fallback.

**Exception scope:** The empty-decline rule applies **only** to `.references`. `.definition` and `.declaration` answers remain authoritative-empty (they return an empty `.ready` answer, blocking the ladder). This preserves correct behavior for definition/declaration while allowing references to fall back to text search.

**Text tier change:** `TextSearchNavigationProvider` now also declines `.hover`, ensuring hover is truly LSP-only (no syntactic or text tier fallback for hover).

**Note on true cross-file references:** sourcekit-lsp returns an empty array for `.references` without a project-wide index. The proper fix is enabling sourcekit-lsp's index store via the `ServerDescriptor.initializationOptions` (which flows into the LSP `initialize` handshake) **AND** a project build that produces the index. As of P3 (2026-07-17), the curated `sourceKitLSP` descriptor sets `initializationOptions: .object(["backgroundIndexing": .bool(true)])` in `Registry/CuratedCatalog.swift`, enabling background indexing. Cross-file references now populate after a real project build produces the index store. The exact key string is re-confirmed against a live installed sourcekit-lsp binary during P5; older versions ignore the unknown key harmlessly. Text tier remains the fallback floor when references are empty. Two offline tests assert the flag in the catalog descriptor and verify the round-trip through the `initialize` handshake.

### Context menu with navigation commands (post-fix increment, 2026-07-16)

`RafuTextView.menu(for:)` augments the default copy/paste/lookup menu with navigation commands at the top:
- Go to Definition (⌃⌘J)
- Go to Declaration
- Find References (⌃⌘R)
Followed by a separator, gated on both a wired `navigateAction` AND an identifier at the click position. The command menu selects the clicked symbol and invokes `session.navigate(kind:)`. `super.menu(for:)` is preserved and always called (nil-tolerant).

### Navigation action plumbing: generalized and hooked (post-fix increment, 2026-07-16)

`RafuTextView.goToDefinitionAction` was generalized to a public `navigateAction: (NavigationTargetKind) -> Void` closure, serving both ⌘-click and the context menu. A separate `hoverAction: (Int) async -> EditorHoverInfo?` closure handles hover resolution.

Both closures are:
- Set in `CodeEditorView.makeNSView` and `updateNSView` with `[weak session]` captures
- Cleared in `dismantleNSView`
- Wired through `EditorGroupView` (the composition layer) into both `EditorDocumentView` (code editor) and `MarkdownEditorPresentation` (markdown preview), so both code and markdown-edit contexts get navigation and hover

Closure construction captures the session weakly to avoid retain cycles. New `EditorHoverInfo` (Sendable) carries tooltip payload. No `NavigationRequest`/`NavigationAnswer` shape changes; the new closures integrate at the UI boundary.

### Server→client request handling and work-done progress handshake (P1, 2026-07-17)

To enable real-server indexing progress, Rafu advertises `window.workDoneProgress` capability and responds to server→client `window/workDoneProgress/create` requests:

- **Capability advertisement:** `ClientCapabilities.window` carries an optional
  `WindowClientCapabilities` struct with `workDoneProgress: Bool?` (optional,
  defaults to null). `LanguageServerSession.initialize()` sends
  `ClientCapabilities(window: WindowClientCapabilities(workDoneProgress: true))`
  in the `initialize` handshake. Without this, most production servers (gopls,
  rust-analyzer, sourcekit-lsp) never create a work-done token, so `$/progress`
  (which drives `LanguageServerStatus.Phase.warmingUp`) never surfaces.
- **Server→client request dispatch is a security surface.** `JSONRPCConnection.handleIncomingRequest`
  (actor-isolated, line 180) replies with a null-result success envelope **only**
  to the exact method string `window/workDoneProgress/create`. Every other method
  receives `-32601 methodNotFound`, unchanged. No prefix matching, no conditional
  allowlist, no expansion without an explicit ADR. Type docs and seam comments
  document this boundary.
- **Null-result success encoding:** `JSONRPCSuccessResponseEnvelope` encodes exactly
  `{"jsonrpc":"2.0","id":…,"result":null}`, with `result` as an explicit JSON
  `null` (via `encodeNil(forKey:)` in the encoder), not an omitted key. This
  mirrors the structure of `JSONRPCErrorResponseEnvelope` and matches the LSP spec.
- **`isWarmingUp` vs. `LanguageServerStatus.Phase.warmingUp`.** The session holds a boolean
  flag `isWarmingUp`, which drives `LSPNavigationProvider` to return `.indexing` status.
  This flag is distinct from and independent of `LanguageServerStatus.Phase.warmingUp`,
  which gates `forwardsDocumentChanges` to suppress keystroke forwarding during initialization.
  The P1 handshake drives the session flag only; the phase is used elsewhere for gating.

### Lane 2 seam: session lifecycle only

The seam between lane 1 (`WorkspaceSession`) and lane 2 (Language Intelligence)
is deliberately minimal:

- `WorkspaceSession` owns a `@ObservationIgnored` instance of
  `LanguageIntelligenceCoordinator` and calls four methods:
  - `workspaceDidOpen(at:session:)`
  - `workspaceDidClose()`
  - `documentDidOpen(document:)`
  - `documentDidClose(documentID:)`
- Lane 1 does **not** call `documentDidChange`, and lane 2 does not expect
  it. Lane 2 self-subscribes to each document's `editDeltas()` stream in its
  `documentDidOpen` handler. This ownership is explicit and visible in lane
  2's code, not hidden in the session.
- This is an important boundary for memory and testing: `WorkspaceSession`
  remains testable and focused on file/directory semantics without knowing
  about language servers or incremental parsing. All cross-document
  coordination (cancelling stale requests, feeding deltas to the parser,
  attributing server memory) lives in lane 2.

## Why it matters

These contracts freeze the interface between lane 1's navigation infrastructure,
document editing, and resource tracking and lane 2's LSP client and parser. They
ensure that:

- Requests can degrade gracefully through the navigation tiers without
  conflating identifier matching (text/syntactic) with position-based lookup
  (LSP).
- Hover is a read-only tooltip facility (no side effects, no indexing, no
  caret movement), debounced to avoid spurious server calls on rapid mouse
  motion, and can be dismissed without blocking user edits.
- References naturally fall back to bounded text search when LSP cannot
  provide a project-wide index (interim pragmatic behavior until
  initializationOptions wiring enables true cross-file references).
- Context menus and ⌘-click navigation surface the full navigation ladder
  without duplicating decision logic.
- The document's true per-keystroke signals (`editDeltas`) remain distinct from
  its save-point identity (`revision`), so UI consumers keying off `revision`
  (preview, restoration) are not constantly invalidated.
- AsyncStream's single-consumer design is respected and concurrency transitions
  are explicit.
- Process resource tracking is efficient and visible to the user via the
  Resources surface, without hidden daemon processes or subprocess spawning.
- Format lint rules are enforced and understood, not circumvented.
- The session's responsibility boundary remains clear: lifecycle reporting only,
  not change coordination.

## Reproduction and evidence

All contract types exist and compile:

- Lane-1 Increment 0: `Sources/RafuApp/Navigation/NavigationTypes.swift` (`NavigationRequest` with `position: Int` and `symbolName: String?`); `Sources/RafuApp/Editor/DocumentEditDelta.swift`; `Sources/RafuApp/Models/EditorDocument.swift` (delta publishing); `Sources/RafuApp/Services/ProcessResourceRegistry.swift`; `Sources/RafuApp/Models/WorkspaceSession.swift`.
- Post-fix increment (2026-07-16): `Sources/RafuApp/Services/MemoryPressureMonitor.swift` (@Sendable DispatchSource handler); hover/context-menu integration in `Sources/RafuApp/Views/CodeEditorView.swift`, `EditorGroupView.swift`, `MarkdownEditorPresentation.swift`, `RafuTextView.swift`; `EditorHoverInfo` and `EditorHoverTooltipView` new types; `WorkspaceSession.hoverInfo(at:utf16Offset:)` new method; `LSPNavigationProvider` and `TextSearchNavigationProvider` empty-decline changes.
- LSP-production-readiness P1 warm-up handshake (2026-07-17): `Sources/RafuApp/LanguageIntelligence/LSPTypes.swift` (new `WindowClientCapabilities` struct, `window` field on `ClientCapabilities`, both `Codable, Sendable`); `Sources/RafuApp/LanguageIntelligence/LanguageServerSession.swift` (advertises `workDoneProgress: true` in `initialize`); `Sources/RafuApp/LanguageIntelligence/JSONRPCMessage.swift` (new `JSONRPCSuccessResponseEnvelope` with explicit null result); `Sources/RafuApp/LanguageIntelligence/JSONRPCConnection.swift` (`handleIncomingRequest` security surface: replies success only to `window/workDoneProgress/create`, `-32601` for all other methods).

The format lint rule is standard Swift format behavior, verified by the
`./script/format.sh --lint` check.

## Verification

```bash
swift build
swift test
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify
```

Lane-1 Increment 0: All contract types compile, pass focused tests (NavigationLadderTests, ProcessResourceRegistryTests, EditorDocumentDeltaTests), and the app launches without error. The seam rule is enforced at review time.

Post-fix increment (2026-07-16): Build clean, `swift test` 489/489 passing (485 baseline + 4 new: MemoryPressureMonitor isolation, hover debounce/dismissal, references fall-through, context menu). `./script/format.sh --lint` clean. `./script/build_and_run.sh --verify` green. Advisor final review of the navigation features: **ALL 8 correctness areas CONFIRMED-SAFE** (hover debounce race, retain cycles/leaks, tooltip dismissal, references fall-through, hoverInfo side-effect-freeness, menu, concurrency/isolation, no payload logging). One optional teardown hardening (performClose→close) applied. No defects found.

LSP-production-readiness P1 (2026-07-17): `swift build` clean; `swift test` = 507/507 tests / 20 suites all green (505 baseline + 2 new, scripted server in-memory transport: success-envelope-not-`-32601` for `window/workDoneProgress/create`, AND locked-scope assertion that `workspace/configuration` still gets `-32601`; `initialize`-params assertion that `capabilities.window.workDoneProgress == true`). `./script/format.sh --lint` clean; zero forbidden-path diffs. Advisor final review: **CONFIRMED-SAFE on security surface, no-logging, concurrency/Sendable (no @unchecked), encoding correctness, comment truthfulness, and regression risk.**

## Related code, ADRs, and phases

- `Sources/RafuApp/Navigation/`
- `Sources/RafuApp/Editor/DocumentEditDelta.swift`
- `Sources/RafuApp/Services/ProcessResourceRegistry.swift`
- `Sources/RafuApp/Services/MemoryPressureMonitor.swift` (GCD handler isolation)
- `Sources/RafuApp/LanguageIntelligence/LSPTypes.swift` (WindowClientCapabilities, ClientCapabilities.window)
- `Sources/RafuApp/LanguageIntelligence/LanguageServerSession.swift` (initialize handshake, workDoneProgress)
- `Sources/RafuApp/LanguageIntelligence/JSONRPCMessage.swift` (JSONRPCSuccessResponseEnvelope)
- `Sources/RafuApp/LanguageIntelligence/JSONRPCConnection.swift` (server→client request security dispatch)
- `Sources/RafuApp/LanguageIntelligence/LanguageIntelligenceCoordinator.swift`
- `Sources/RafuApp/Models/EditorDocument.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Views/CodeEditorView.swift` (navigateAction/hoverAction plumbing)
- `Sources/RafuApp/Views/EditorGroupView.swift` (closure threading)
- `Sources/RafuApp/Views/MarkdownEditorPresentation.swift` (markdown hover/navigation)
- `Sources/RafuApp/Views/RafuTextView.swift` (menu(for:), hoverAction integration)
- [`docs/decisions/0005-language-intelligence-and-lsp.md`](../decisions/0005-language-intelligence-and-lsp.md)
- [`docs/plans/phases/language-intelligence.md`](../plans/phases/language-intelligence.md)
- [`docs/plans/phases/lane-1-memory-and-syntax-plan.md`](../plans/phases/lane-1-memory-and-syntax-plan.md)
- [`docs/plans/phases/lane-2-lsp-plan.md`](../plans/phases/lane-2-lsp-plan.md)
- [`docs/plans/phases/lsp-production-readiness.md`](../plans/phases/lsp-production-readiness.md) (P1 warm-up handshake)
- [`docs/plans/phases/post-merge-validation-fixes.md`](../plans/phases/post-merge-validation-fixes.md)
- [`docs/references/concurrency.md`](concurrency.md) (GCD DispatchSource handler isolation)
