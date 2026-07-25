# Memory attribution: what Rafu can honestly report, and what it cannot

- **Applies to:** the Resources popover (`ResourcesView`), `MemoryTimeline`,
  `MemoryComposition`, `ProcessMemorySampler`, `ProcessResourceRegistry`,
  and any future surface that shows "where the memory went"
- **Last verified:** Swift 6.2.4, macOS 26, 2026-07-26

## Rule or observed behavior

**1. macOS gives no per-subsystem breakdown of a task's own resident size.**
`mach_task_basic_info.resident_size` (`ProcessMemorySampler`) is a single
number for the whole process. There is no API that answers "how much of my
RSS is text storage vs. tree-sitter trees vs. diff caches." Any UI that
partitions that number into named categories is fabricating the partition.
Rafu therefore reports memory from three sources of DIFFERENT quality, kept
visually and structurally separate:

- **Measured, per-process** — Rafu's own RSS plus one row per pid in
  `ProcessResourceRegistry`, grouped by `ProcessKind` into sections with
  per-category totals (`MemoryComposition.groups(from:)`). These are real,
  independent numbers from `proc_pid_rusage`.
- **Counted, in-process** — exact counts of what a window holds
  (`WorkspaceContentMetrics`: open tabs split loaded/hibernated, unsaved
  tabs, terminal sessions, file-index entries, open diff). Counts, never
  byte estimates.
- **Correlated over time** — `MemoryTimeline` readings annotated with what
  the app had just done.

**2. Do not size live buffers by snapshotting their text.** The obvious way
to put bytes on the "open tabs" row is `EditorDocument.textSnapshotProvider`
× every mounted document. That allocates a full `String` duplicate of every
open file *on every refresh of a memory panel* — spending the resource being
measured, on a 2s cadence, to produce a number that still would not be a
slice of RSS. This is why the content section is counts-only, and why the
row labels say "Open tabs / 8" rather than "Open tabs / 8 (14.2 MB)".

**3. A timeline delta is an interval correlation, not an action's cost.**
`MemoryTimelineEntry.deltaBytes` is the change in whole-process resident
memory between the previous reading and this one. Everything happening in
that interval lands in the same number: allocator slack, framework caches,
off-main tree-sitter parsing, and lazy deallocation that has not run yet.
The UI states this in the Timeline tab rather than implying causation, and
the type's doc comment carries the same contract so a future caller does not
"improve" the label into a claim.

**4. Read AFTER the work, and let it settle.** Most of what an action costs
is allocated after the call that starts it returns — opening a tab registers
an `EditorDocument` synchronously, but SwiftUI mounts the `NSTextView`,
TextKit builds the storage, and the highlighter parses on later turns.
Reading at the call site attributes the spike to whichever event comes next.
`MemoryTimeline.note(_:detail:)` is the call-site API and defers its reading
by `MemoryTimeline.settleDelay` (400 ms); `record(_:detail:)` reads
immediately and exists for the periodic sampler and for tests.

**5. Event readings are not a poll.** `note` schedules a ONE-SHOT `Task` per
event — event-driven, in the same category as the one-shot toast reset in
the polling audit, not a standing timer. The only periodic readings come
from `ResourcesView`'s existing visible-only `.task` loop, which is
cancelled when the popover closes. The "no standing background poll" result
in [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md) still holds.

**6. A drop in RSS must not wrap.** Resident sizes are `UInt64`; a release
is a negative delta. `MemoryTimelinePolicy.delta(from:to:)` converts through
`Int64(bitPattern:)` before subtracting, and a `nil` previous reading (the
first of the session, or the first after `clear()`) yields 0 rather than a
fabricated jump from zero. Regression-tested — an unsigned subtraction here
renders a 250 MB release as a ~18-exabyte increase.

**7. A flat series normalizes to a mid-line, not NaN.**
`MemoryTimelinePolicy.normalized` divides by the series range; a flat or
single-point series has range 0. It returns 0.5 for every point so flat
memory draws a flat line instead of a blank graph.

**8. Hibernation events fire only on a transition.**
`WorkspaceSession.updateHibernationStates` runs on every selection change.
It counts documents whose `loadState` actually changed to `.hibernated` and
files an event only when that count is non-zero — otherwise the timeline
fills with one row per tab switch and buries real activity.

**9. Everything except one section is process-wide, and must say so.** Every
Rafu window is a `WindowGroup` scene in ONE process, so there is exactly one
RSS number, one `ProcessResourceRegistry`, and one `MemoryTimeline` behind
every window's popover. Per-window resident memory is not merely unimplemented
— the kernel has no per-window accounting to expose. Consequences the UI must
carry rather than hide:

- The status-bar figure, the "Rafu (this app)" row, the process sections, and
  the whole Timeline tab are identical in every window. The process section
  headers are therefore titled "… — All Windows" and the caption says so;
  without it, "Terminals · 5" in a window with two terminals reads as a bug.
- The only window-scoped part is the `WorkspaceContentMetrics` section,
  titled "This Window Only" for the contrast.
- Timeline rows carry a `source` (the originating workspace's display name)
  and render "in <name>" ONLY when it differs from the window being looked at
  (`MemoryTimelinePolicy.subtitle(for:currentWindow:)`). Annotating local rows
  too would put a label on nearly every row and bury the foreign ones.
  Granularity is the workspace name, so two windows on the SAME workspace read
  alike — the honest limit of what the event sites know, and it reads
  correctly either way ("it happened in that project"). App-level events
  (memory pressure) carry an empty source and are never labelled.
- `WorkspaceTerminalManager.memoryTimelineSource` is a CLOSURE, not a stored
  string, wired in `installTerminalHandlersIfNeeded()` alongside the other
  callbacks: a window's workspace (and so its display name) can change under
  a live manager.

**10. Privacy.** `MemoryTimelineEntry.detail` carries file names, terminal
display names, and counts — the same strings already visible in tab labels.
Never document text, never a full path. The whole ring is in-memory,
bounded (`eventCap` 120 events, `readingCap` 180 readings), and never
persisted, logged, or transmitted; it dies with the process.

## Why it matters

"Break the memory number down into categories" is a reasonable request that
has no honest literal answer on macOS. Answering it literally — inventing a
plausible partition of RSS — would produce a panel that looks authoritative
and misleads every future performance investigation, including Rafu's own
~150 MB idle budget work, which must be validated in Release builds with
Instruments rather than from this popover. Splitting the answer into
measured / counted / correlated keeps the panel useful without making a
claim the platform cannot support.

## Reproduction or evidence

- Per-process rows come from `proc_pid_rusage(RUSAGE_INFO_V2)`; the
  whole-app row from `task_info(MACH_TASK_BASIC_INFO)`. There is no third
  API returning a per-subsystem split — the absence is the finding.
- Delta wrap-around, flat-series normalization, ring-buffer eviction,
  newest-first ordering, group ordering/totals with exited pids,
  zero-category omission, and foreign-window labelling are all covered
  headlessly in
  `Tests/RafuAppTests/MemoryTimelineTests.swift` (`MemoryTimeline.sampleResident`
  is injectable, so tests script readings instead of sampling this
  process's real, unrepeatable RSS).

## Verification

```bash
swift build
swift test          # MemoryTimelineTests + existing ResourcesView format tests
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify
rg -n "MemoryTimeline.shared.note" Sources/RafuApp   # every event call site
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Services/MemoryTimeline.swift`
  (`MemoryEventKind`, `MemoryTimelineEntry`, `MemoryTimelinePolicy`)
- `Sources/RafuApp/Services/MemoryComposition.swift`
  (`MemoryProcessGroup`, `WorkspaceContentMetrics`, `ContentMetricRow`)
- `Sources/RafuApp/Views/ResourcesView.swift`
  (Composition/Timeline tabs, `MemorySparkline`, `WorkspaceContentAdapter`)
- `Sources/RafuApp/Services/ProcessResourceRegistry.swift`
  (`ProcessKind` is `String`-raw-valued/`Hashable` for grouping)
- Event call sites, each passing a `source`: `WorkspaceSession`
  (`memoryTimelineSource`; document open/close/hibernate, git refresh, diff
  open/close, file-index build), `WorkspaceTerminalManager`
  (terminal open/close), `WorkspaceSearchModel` (search complete),
  `MemoryPressureMonitor` (pressure warning/critical — app-level, no source)
- [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md) (pressure
  response, cap table, polling audit)
- [`editor-working-set-and-hibernation.md`](editor-working-set-and-hibernation.md)
  (what "loaded" vs "hibernated" counts mean)
- [`memory-and-file-indexing.md`](memory-and-file-indexing.md)
