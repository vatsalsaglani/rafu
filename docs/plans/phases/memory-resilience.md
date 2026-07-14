# Memory resilience and responsiveness hardening

## Status

Planned. Post-initial-push and cross-cutting; increments may interleave with
feature phases, but each lands with its own measurement evidence.

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
