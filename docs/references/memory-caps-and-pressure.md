# Memory pressure response and resource caps

- **Applies to:** app-level memory-pressure monitoring, document hibernation, file-name index shedding, and upstream process limits on output buffers and request bodies
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-15

## Rule or observed behavior

**Memory-pressure response:**

- App-level `MemoryPressureMonitor` (@MainActor, static let shared) owns a single `DispatchSourceMemoryPressure` on a private serial queue; the source watches for `[.warning, .critical]` pressure signals. `start()` is idempotent, calling `resume()` exactly once. The monitor is started in `RafuAppDelegate.applicationDidFinishLaunching`.
- `WorkspaceSession` instances register with the monitor via a weak `NSHashTable<WorkspaceSession>` (auto-prunes closed windows). Registration occurs in `WorkspaceSceneRoot`'s `.task` modifier.
- When the monitor receives a pressure signal, it calls `broadcast(_:)` (@MainActor), the testable seam, which invokes each registered session's `respondToMemoryPressure()` method (exact behavior described below). The source is purely kernel-event-driven, with no polling or standing timers.
- `WorkspaceSession.respondToMemoryPressure()`: hibernates all eligible documents via `updateHibernationStates(bypassNewestGrace: true)` — this is the increment-4/5 existing path; dirty and visible documents are never hibernated. Then sheds the filename index: cancels any in-flight rebuild, sets `fileIndexState = .idle`, calls `fileIndex.shed()`, and bumps `fileIndexGeneration` so in-flight palette queries see the stale generation and restart.
- `WorkspaceFileNameIndex.shed()` (actor): drops the cached paths snapshot. `ensureFileIndexReady()` rebuilds on demand when the command palette next runs a file-mode query, so shedding is invisible to the user beyond a brief "Indexing files…" state.
- Symbol-index shedding is deferred as an increment-10 extension point.

**Resource caps:**

These limits are coordinator-verified real values. They protect against runaway subprocess output, AI provider requests/responses, and search result explosion.

| Cap | Value | Source | Purpose |
|---|---|---|---|
| Terminal scrollback | 500 lines | SwiftTerm default (not set in Rafu code); ADR 0004 | Bounded terminal history |
| Git subprocess stdout & stderr (each, separately) | 64 MB → throws `outputTooLarge` | GitCommandRunner.swift:21,96-97 | Prevents unbounded `git log`, `git diff`, etc. from filling memory |
| AI request body max | 512 KB → throws `requestTooLarge` | AIProviderRequestBuilder.swift:4,66 | Bounded user-initiated AI requests (commit drafts, explanations) |
| AI decoded output max | 64 KB → throws `responseTooLarge` | AIProviderClient.swift:9 | Prevents runaway AI response decoding |
| AI raw wire bytes max | 2 MB → throws `responseTooLarge` | AIProviderClient.swift:10 | Bounded network transfer for AI responses |
| AI per-SSE-event max | 1 MB | ServerSentEventParser.swift:10 | Single server-sent-event size limit during streaming |
| AI max output tokens | default 256, range 16…2048 | AIProviderConfiguration.swift:79,58 | Bound inference cost and response time |
| Search: max file bytes | 2 MB (skip larger) | WorkspaceSearchModels.swift:11 | Avoid indexing/scanning huge binaries or generated files |
| Search: max files visited | 20,000 (then truncate) | WorkspaceSearchModels.swift:12 | Bounded search result enumeration |
| Search: max matches per file | 500 | WorkspaceSearchModels.swift:13 | Prevent one-file result explosion |
| Search: max total matches | 5,000 (then truncate) | WorkspaceSearchModels.swift:14 | Bounded UI result list |
| Search: max preview chars | 240 | WorkspaceSearchModels.swift:15 | Bounded preview text in search results |
| Search: binary sniff window | first 8,192 bytes for NUL | WorkspaceSearchService.swift:261 | Early exit on binary files |
| Filename index entries | 200,000 (truncation disclosed) | WorkspaceFileNameIndex.swift:22 | Bounded palette index; `isTruncated` flag shown |
| Buffer symbol scan (@ palette) | 2,000 symbols | BufferSymbols.swift:31 | Bounded `@`-symbol extraction per document |
| Large-file guard: max unguarded bytes | 2 MB | DocumentGuardPolicy.swift:23 | Syntax parsing guard threshold |
| Large-file guard: max line length | 10,000 UTF-16 units | DocumentGuardPolicy.swift:29 | Long-line parsing guard threshold |
| Undo levels | 200 | CodeEditorView.swift (`undoLevelCap=200`) | Bounded undo stack per document |

## Why it matters

Memory-pressure response keeps the app responsive under kernel-signaled memory warnings without adding polling or standing timers. Shedding the filename index on pressure is invisible to the user (rebuilds on demand), freeing a typically ~2-5 MB snapshot from transient pressure relief.

Resource caps protect against:
- Subprocess runaway (git output filling pipes and memory)
- AI request/response explosion (cost explosion, network timeouts, buffer overflow)
- Search result explosion (UI lag, result display timeout)
- Unbounded index growth (palette becoming slow on very-large workspaces)

Each cap is measured independently and fails fast with a clear error (e.g., `outputTooLarge`), never silently truncating mid-operation.

## Reproduction and evidence

**Memory-pressure monitor:**

- `DispatchSourceMemoryPressure` is the standard Darwin/macOS kernel pressure-signaling mechanism; no polling. Testability is via the `broadcast(_:)` seam: tests call it directly instead of triggering real pressure.
- Session registration is auto-pruning: closed windows (deallocated `WorkspaceSession` instances) are removed automatically from the weak `NSHashTable`.

**Polling audit:**

- Comprehensive grep search of the codebase for `Timer`, `DispatchSourceTimer`, `Task.sleep`-based loops, and `RunLoop` polling yielded zero standing-poll timers in the category of real background work.
- Approved visible-only samplers: `ResourcesView.swift:54-65` and `WorkspaceStatusBar.swift:51-65` (only while the view is visible; `.task` loop exits on disappear).
- Legit kernel-bounded work: `WorkspaceLivenessService.swift:218-225` (FSEvents 400ms trailing debounce, not a poll).
- Short-lived subprocess wait: `GitCommandRunner.swift:75-79` (20ms while a git process is alive; only during active git operation).
- One-shot toast reset: `AIThemeGeneratorSection.swift:81` (not a loop).
- **Conclusion:** No standing background poll exists.

## Verification

```bash
swift build
swift test
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify
```

All 193 tests pass; 7 new tests added for the filename-index shedding and search-caps/cancellation behavior. Polling audit was run via grep across the codebase; all findings are classified above.

## Related code, ADRs, and phases

- `Sources/RafuApp/Delegate/MemoryPressureMonitor.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift` (respondToMemoryPressure, register seam)
- `Sources/RafuApp/Services/WorkspaceFileNameIndex.swift` (shed method)
- `Sources/RafuApp/Editor/` (hibernation policy, document lifecycle)
- `Sources/RafuApp/Services/` (search, git, AI buffer caps)
- `docs/decisions/0004-embedded-terminal.md` (terminal scrollback cap origin)
- `docs/plans/phases/lane-1-memory-and-syntax-plan.md` (increment 6 context)
