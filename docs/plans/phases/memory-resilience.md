# Memory resilience and responsiveness hardening

## Status

Planned. Post-initial-push and cross-cutting; increments may interleave with
feature phases, but each lands with its own measurement evidence.

**Work log, 2026-11-15 — autorelease pools (merge 9f763f1).** Synchronous
Foundation-heavy loops in Agent History and the workspace symbol index now run
each unit inside RafuCore `withAutoreleasePool`, and kept strings are copied
native with `makeContiguousUTF8()`. Debug-process harness over real transcripts:
after scan 88.6–88.8 → 13.0–13.8 MB; after message search over 170 sessions
1,090 → 62.5 MB. A debug-build note was added to Resources and the memory chip
tooltip. Evidence and numbers:
[`autorelease-pools-in-swift-concurrency-loops.md`](../../references/autorelease-pools-in-swift-concurrency-loops.md).
The implementor ran format, build and the full parallel suite green on the
branch; the main gate (both modes) is run by the coordinator. The app-level
footprint after the fix is pending. Deferred: D1 lazy symbol index (needs user
approval), D2 find the 94k `CFString` objects with `MallocStackLogging`, D3 card
shadows only if Instruments shows them idle.

**Work log, 2026-11-15 — D2 follow-up (merge 56369ec "enumerator pools, native
strings, regression tests").** Toolchain: Swift 6.4.2, Xcode with macOS 27.2 SDK
(26B118), Darwin 27.2.0, Mac17,13. D2 investigation: the running Lightning after
the pool fix had 15,861 `CFString` objects (775 KB), not 94k. A symbol-name probe
over 1,097 Swift files (about 57k names) showed the old
`(text as NSString).substring(with:)` kept 36,366 `CFString` objects plus 36,366
storage blocks (about 2.7 MB); with `makeContiguousUTF8()` the extra is 0. An
enumerator loop without a pool kept 137k `CFString` objects (22 MB) over `.build`
trees. Changes: per-step pools in `WorkspaceFileNameIndex.enumeratedPaths`
(non-git fallback), `WorkspaceSymbolIndex.enumeratedPaths`, and
`WorkspaceSearchService.scan`; kept paths and the Codex `thread_name` title are
native. About 38 to 40k of the old 94k stay unexplained (likely a second symbol
array set during a rebuild, D1, or undrained autoreleased objects; not verified).
**Found and fixed (commit 2244217, 2026-11-15):** a pre-existing bug in the
non-git enumerator fallback (a symlink to a directory before sibling directories
dropped the first sibling, because `skipDescendants()` was called for the
symlink). Rule: [`memory-and-file-indexing.md`](../../references/memory-and-file-indexing.md).
The Codex history scanner change is a guard only (no loss was reproduced there).
Main, both modes green after the fix and the test merges: parallel and serial
each 470 tests in 33 suites and 3801 tests in 308 suites.
**Owed (user):** the `heap -s -q --forkCorpse` check after History plus one
conversation plus a workspace refresh; expected fewer than about 25k `CFString`
objects and one symbol array set (about 1.7k arrays, 3.4 MB); two sets means D1.
The branch parallel suites were green; main gate run by coordinator. Details:
[`autorelease-pools-in-swift-concurrency-loops.md`](../../references/autorelease-pools-in-swift-concurrency-loops.md).

Motivation: on 2026-07-14 the eager recursive file tree took a large monorepo
to roughly 900 MB–1 GB resident. The fix (lazy per-directory tree plus a
background filename index — see
[`docs/references/memory-and-file-indexing.md`](../../references/memory-and-file-indexing.md))
restored ~47–49 MB idle on a synthetic 100k-file workspace and proved this
failure class is real, not theoretical. This brief engineers out the rest of
the class before users hit it, using the documented history of VS Code and
Cursor memory incidents as the checklist.

## Product outcome

Rafu's defining promise is a repository workbench that stays light under
real-world abuse: huge files, huge repos, file-event storms, long sessions,
many tabs, many windows. Every mechanism below has burned VS Code or Cursor
users at scale; Rafu adopts the guard proactively instead of rediscovering
the incident.

## Lessons ledger

Each item: the editor-history failure, then the Rafu guard.

1. **Large and minified files freeze tokenizers.** VS Code capped
   tokenization line length (~20k chars) and disabled folding, bracket
   matching, and tokenization past size thresholds only after years of
   one-line-minified-JSON freezes. → Guard mode: past per-file byte or
   line-length thresholds a document opens as plain text (no highlighting,
   no symbol scan, no indexing) with a visible banner and a one-click
   override. Typing budgets hold in guard mode.
2. **The text buffer duplicated itself.** VS Code rewrote its line-array
   buffer as a piece tree because per-line string arrays exploded memory on
   big files. → `NSTextStorage` stays the only full-text owner (standing
   invariant); snapshots for search/AI/symbols are bounded, transient, and
   never retained per-line.
3. **Un-attributed memory destroys trust.** The extension host made "why is
   my editor using 4 GB" unanswerable until VS Code shipped a Process
   Explorer. → A **Resources surface**: app RSS plus every Rafu-spawned
   child (terminal shells, git, language servers) with name and honest
   per-process RSS at a low refresh rate. The memory promise becomes visible
   product surface, not a footnote.
4. **Language servers grow without ceilings.** tsserver's multi-GB growth
   earned its own `maxTsServerMemory` setting. → Per-server RSS ceiling,
   lazy start, idle shutdown (ADR 0005); enforcement is observable here via
   the Resources surface.
5. **Watcher storms.** Recursively watching `node_modules` melted CPU and
   memory until VS Code moved to native watchers plus exclude globs. →
   FSEvents, 400 ms debounce, and materialized-directory-only re-listing
   already exist; add a **storm circuit breaker**: bursts past a threshold
   (branch checkout, dependency install) collapse into one coalesced
   refresh, never per-directory work times N.
6. **Search results held in memory.** VS Code keeps search out-of-process
   (ripgrep) and caps results (~20k) because unbounded in-process result
   lists froze the renderer. → Result caps with truncation disclosure,
   batched streaming into the UI, binary/size skips, and buffers verifiably
   released on cancellation.
7. **Unbounded ring buffers.** Output channels and terminal scrollback
   growing without limit are recurring editor leak reports. → Documented
   caps everywhere: terminal scrollback (bounded at 500 today — stays
   bounded if made configurable), git operation output, AI response
   streams, error strings.
8. **Tab accumulation.** Dozens of open editors, each holding text, tokens,
   and undo history. → **Background-tab hibernation**: non-visible,
   non-dirty documents past a threshold (or under memory pressure) release
   their `NSTextStorage` and syntax tree, keep path/selection/scroll
   metadata, and reload on focus. Dirty documents never hibernate. Undo
   stacks are capped.
9. **Eager restoration.** Restoring a large session resolves every editor at
   launch. → Restoration materializes placeholders; only visible editors
   load content.
10. **Git status churn on monorepos.** Periodic polling on huge repos costs
    CPU and battery; VS Code adopted untracked-cache and fsmonitor
    acceleration late. → No polling timers anywhere (event-driven refresh
    only, audited); document opt-in `core.fsmonitor`/untracked-cache
    acceleration for monorepos; status parsing streamed and capped (the
    12,623-changed-files case observed on 2026-07-13 becomes a regression
    scenario).
11. **AI indexing blowups.** Cursor-class background embedding/indexing of
    whole repositories costs gigabytes of RSS and disk, plus unbounded chat
    history. → AI stays request-scoped: no background embedding indexer
    without its own product ADR; prompt budgets bounded (existing); AI
    history persisted to disk, never retained unbounded in memory.
12. **Decorative rendering scales with the document, not the viewport.**
    Minimaps render entire documents; decorations pile up. → No minimap
    (recorded as deliberate); gutter and diagnostic decorations bounded to
    visible-plus-margin ranges.
13. **Budgets rot without procedure.** → Release-build measurement scenarios
    recorded in `memory-and-file-indexing.md`, plus a memory-pressure
    response: on system pressure notifications Rafu sheds syntax trees,
    index snapshots, and hibernatable documents.

## Acceptance contract

1. Files past guard thresholds open in plain-text guard mode with a banner
   and one-click override; typing stays within the one-frame p95 budget in
   and out of guard mode.
2. A Resources surface reports app RSS and every Rafu-spawned child process
   with honest per-process numbers (within tolerance of `ps`), refreshed at
   low frequency, reachable from the status item and a menu path.
3. Background documents hibernate per policy; dirty documents never
   hibernate; refocus restores content, selection, and scroll exactly; undo
   caps are documented.
4. A ≥ 2,000-path FSEvents burst produces one coalesced refresh cycle with
   measured peak RSS recorded (baseline: ~70 MB peak on the 2026-07-14
   synthetic run).
5. Workspace search enforces caps with disclosure; cancellation returns
   memory to baseline (measured).
6. Session restoration loads content only for visible editors; hidden tabs
   are placeholders until focused.
7. An audit confirms zero polling timers; all refresh is event-driven; an
   fsmonitor/untracked-cache acceleration note exists for monorepos.
8. Terminal scrollback, git output, and AI stream caps are documented with
   their values and covered by tests where feasible.
9. Under simulated memory pressure Rafu sheds recoverable caches and the
   Resources surface shows the drop.
10. Release-build measurements are recorded for: idle with no workspace, a
    100k-file workspace open, ten tabs across three windows, the terminal
    panel open, and the 2,000-file churn scenario — idle stays under the
    150 MB plan budget.

## Architecture locks

- All standing invariants hold: no live text in observation, open-buffer-only
  parsing, event-driven Git, executable-plus-argument-array processes.
- New standing rule introduced by this brief: **any feature that holds
  per-file or per-event state must declare its bound — cap, eviction, or
  hibernation — in its phase brief. Unbounded is a design-time bug.**
- Guards must not punish normal use: thresholds are generous, overrides are
  one click, and guard mode is visibly explained — never silent feature
  loss.

## Verification

- Swift Testing coverage for every policy: guard thresholds, hibernation
  eligibility, caps, storm coalescing (pure logic extracted, matching the
  existing `WorkspaceChangeClassifier`-style pattern).
- Instruments/signpost evidence for the typing path in guard and normal
  modes.
- The `ps`-based scenario procedure in `memory-and-file-indexing.md`
  extended to the acceptance scenarios and re-run in Release configuration.
- Manual pass: Resources numbers versus `ps` on live processes;
  memory-pressure simulation.

## Sequencing and ownership

Cross-cutting; increments are safe in any order after the initial push, but
the Resources surface should land early — it is the observability foundation
that [`language-intelligence.md`](language-intelligence.md) server ceilings
report into. Owned paths are chosen per increment; `WorkspaceSession.swift`,
`Package.swift`, and shared indexes remain integration-owned.

When run under the two-lane worktree split defined in
[`language-intelligence.md`](language-intelligence.md), this brief plus
Stages A–B form lane 1, which owns `Package.swift`,
`WorkspaceSession.swift`, editor paths, the navigation UI, and the
Resources surface; the Resources surface builds on the shared
`ProcessResourceRegistry` contract so lane 2's servers appear in it without
cross-lane edits.
