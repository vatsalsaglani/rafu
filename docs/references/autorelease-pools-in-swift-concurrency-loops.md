# Autorelease pools in Swift concurrency loops

- Applies to: any synchronous loop (no `await`) that creates Foundation
  objects inside a Swift concurrency job: `JSONSerialization` trees,
  `FileHandle` `NSData`, bridged `String` values. Today that is
  `Sources/RafuCore/AgentHistory/**` and
  `Sources/RafuApp/Services/WorkspaceSymbolIndex.swift` and
  `WorkspaceSymbolExtractor.swift`. The helper is
  `Sources/RafuCore/AutoreleasePool.swift`.
- Last verified: Xcode with macOS 27.2 SDK (26B118), Swift 6 language mode,
  Darwin 27.2.0, Mac17,13, 2026-11-15. Measurements are from a debug (`-Onone`)
  process.

## Rule or observed behavior

Swift concurrency drains a thread's autorelease pool only when a job ends. A
synchronous loop that creates autoreleased Foundation objects keeps all of them
alive until the whole job ends. The freed pages then stay charged to the
process (`phys_footprint`) because the malloc zone grew to the peak and does
not give pages back.

The fix is `withAutoreleasePool(_:)` in RafuCore:

- It calls `autoreleasepool` under `#if canImport(ObjectiveC)` and calls the
  body directly elsewhere. It is synchronous and `rethrows`.
- `await` cannot be inside the body. Wrap one unit of work per pass.
- A value the body returns stays valid after the pool drains (Swift retains it
  first).

Where the pools are:

| Site | Unit of work |
|---|---|
| `AgentHistoryJSON.object` | one `JSONSerialization` parse |
| `AgentHistoryJSONLines.forEachLine` | one chunk read and one line handed to the body |
| `AgentHistoryScanner.scan` | one file |
| `AgentHistoryMessageSearch` | one session |
| `WorkspaceSymbolIndex` `buildSymbols` and `applyDirectoryChange` | one file |

Strings that are kept after the pool must be native, not bridged. A bridged
`String` can pin the `NSString` it came from, so the pool frees nothing. Kept
strings are copied with `makeContiguousUTF8()`: `AgentHistoryJSON.native`,
`nonEmptyString`, `AgentTranscriptBuilder` item text and detail, and
`WorkspaceSymbolExtractor` names.

What does not help (measured):

- `malloc_zone_pressure_relief` returned 0 MB. Only preventing the growth works.
- Linking WebKit, AVFoundation, AVKit, Charts, and MetalKit changes the
  footprint by about 0 MB, so lazy framework loading saves nothing.

## Why it matters

Reading the user's real Agent History made a debug process grow far past what
it used. Without a pool per unit, the footprint after one scan or one search is
the peak of the whole job, and the Resources panel and the status bar show it
(they read `phys_footprint`, the same number as Activity Monitor; see
[`memory-footprint-and-timer-tolerance.md`](memory-footprint-and-timer-tolerance.md)).

## Reproduction or evidence

Advisor measurement on the running debug Rafu Lightning (History visible,
Ensemble with 2 shells, one conversation open), before the fix:

- `phys_footprint` 198 MB (peak 369 MB).
- "2 terminals 17 MB" in Resources is the child shells, not Rafu.
- Malloc Small 119 MB, of which 52.7 MB (45 %) is fragmentation. One empty
  20.3 MB large region is still charged.
- IOSurface 22 MB: window backing store 13.2 MB and two purgeable Ensemble card
  shadow drawables (4.2 MB and 4.7 MB).
- Live heap 81 MB: unidentified `CFString` 10.7 MB (94k objects), SwiftUI graph
  about 15 to 20 MB, Swift metadata 6 MB, symbol index 3.4 MB, SwiftTerm
  buffers under 0.2 MB.
- `leaks`: 0.

Measured by a temporary test harness over the user's real `~/.claude/projects`
and `~/.codex`, read-only, in a debug process. Baseline 8.9 MB. 283 files, 170
sessions. The largest transcript is 240 MB on disk (the load bound is 20 MiB).
The harness is not in the repository.

| Step | Before | After |
|---|---|---|
| After scan | 88.6 to 88.8 MB | 13.0 to 13.8 MB |
| After largest transcript load | 146.0 MB | 31.4 MB |
| After message search over 170 sessions | 1,090 MB (peak 1,090) | 62.5 MB (peak 62.8) |
| Transcript load after the search | 1,143 MB | 64.5 MB |

Advisor probes: scan 81 to 6 MB; transcript 53 to 33 MB.

App-level footprint after the fix: pending (the coordinator measures it; see
the profile row in [`ensemble-memory-profile.md`](ensemble-memory-profile.md)).

Estimates, not measurements: Release today about 160 to 175 MB; Release after
the fixes about 100 to 125 MB; debug after the fixes about 120 to 145 MB.

Deferred, not done:

- D1: a lazy symbol index. It rebuilds on each workspace refresh today
  (`WorkspaceSession.swift` near lines 2857, 3445, 3464, 3476). It needs user
  approval.
- D2: find the 94k `CFString` objects with `MallocStackLogging` on a renamed
  copy of the app.
- D3: the Ensemble card shadow drawables, only if Instruments shows them idle.

Debug note: a debug build uses more memory than a release build, so the debug
number is not the release number. `DebugBuildNote` ("This is a debug build. It
uses more memory than a release build.") shows in the Resources popover caption
and in the memory chip tooltip (`MemoryChipPresentation.help`) under `DEBUG`
only. The number is never scaled.

### Test hygiene

The test target fails on any Swift warning. A nested `try #require` inside
another `#require` produces one. Hoist the inner value into a `let` first.

## Verification

Each implementor ran format, build, and the full parallel suite green on its
branch. The main gate (both modes) is run by the coordinator; no serial result
is recorded here.

```bash
rg -n "withAutoreleasePool|makeContiguousUTF8" Sources
swift test --filter AgentHistory
swift test --filter WorkspaceSymbol
```

To re-measure: run Rafu Lightning only, then
`footprint "$(pgrep -x RafuLightning)"` and
`vmmap --summary "$(pgrep -x RafuLightning)"`. Never target a bare `Rafu`.

## Related code, ADRs, and phases

- `Sources/RafuCore/AutoreleasePool.swift`
- `Sources/RafuCore/AgentHistory/AgentHistoryJSONLines.swift`,
  `AgentHistoryScanner.swift`
- `Sources/RafuApp/Services/WorkspaceSymbolIndex.swift`,
  `WorkspaceSymbolExtractor.swift`
- `Sources/RafuApp/Views/ResourcesView.swift` (`DebugBuildNote`),
  `ProcessMemorySampler.swift`
- [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md),
  [`ensemble-memory-profile.md`](ensemble-memory-profile.md),
  [`memory-attribution-and-timeline.md`](memory-attribution-and-timeline.md),
  [`agent-history.md`](agent-history.md),
  [`workspace-symbol-index.md`](workspace-symbol-index.md)
- Phase: [`memory-resilience.md`](../plans/phases/memory-resilience.md)
