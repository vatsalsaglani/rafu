# Navigation ladder and LSP client contracts

- **Applies to:** navigation types and providers, document edit deltas, the
  Language Intelligence subsystem seam, and process resource registration
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-14

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

All contract types exist and compile in the lane-1 Increment 0 commit:

- `Sources/RafuApp/Navigation/NavigationTypes.swift`: `NavigationRequest`
  definition with `position: Int` and `symbolName: String?`.
- `Sources/RafuApp/Editor/DocumentEditDelta.swift`: delta shape with
  `editVersion` counter.
- `Sources/RafuApp/Models/EditorDocument.swift`: publishes deltas via
  `editDeltas()` and maintains the continuation registry.
- `Sources/RafuApp/Services/ProcessResourceRegistry.swift`: uses `proc_pid_rusage`.
- `Sources/RafuApp/Models/WorkspaceSession.swift`: owns
  `LanguageIntelligenceCoordinator` and calls the four lifecycle methods.

The format lint rule is standard Swift format behavior, verified by the
`./script/format.sh --lint` check.

## Verification

```bash
swift build
swift test
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify
```

All contract types compile, pass the focused tests (NavigationLadderTests,
ProcessResourceRegistryTests, EditorDocumentDeltaTests), and the app launches
without error. The seam rule is enforced at review time (no `documentDidChange`
call from session to coordinator) and verified by the fact that lane 2's
coordinator initializes document subscriptions in its `documentDidOpen` handler
alone.

## Related code, ADRs, and phases

- `Sources/RafuApp/Navigation/`
- `Sources/RafuApp/Editor/DocumentEditDelta.swift`
- `Sources/RafuApp/Services/ProcessResourceRegistry.swift`
- `Sources/RafuApp/LanguageIntelligence/LanguageIntelligenceCoordinator.swift`
- `Sources/RafuApp/Models/EditorDocument.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- [`docs/decisions/0005-language-intelligence-and-lsp.md`](../decisions/0005-language-intelligence-and-lsp.md)
- [`docs/plans/phases/language-intelligence.md`](../plans/phases/language-intelligence.md)
- [`docs/plans/phases/lane-1-memory-and-syntax-plan.md`](../plans/phases/lane-1-memory-and-syntax-plan.md)
- [`docs/plans/phases/lane-2-lsp-plan.md`](../plans/phases/lane-2-lsp-plan.md)
