# Command palette and file-search pitfalls

- Applies to: `CommandPaletteView`'s result list, `WorkspaceFileNameIndex`,
  and manual GUI verification of any of the above via
  `./script/build_and_run.sh`
- Last verified: Swift 6.2.4, macOS SDK 26.x, 2026-07-19

## Rule or observed behavior

Three distinct root causes combined to make "command palette search is
broken" / "file search is slow" a long, confusing debugging session. Record
all three so none of them is rediscovered from scratch.

**1. SwiftUI dual-identity render bug.** `CommandPaletteView.resultsList`
combined `ForEach(Array(rows.enumerated()), id: \.element.id)` (element
identity) with a per-row `.id(index)` (positional identity) on the row view
itself. When the result set changed but kept the same row *count*, SwiftUI
reused the old row views under their positional identity and rendered stale
titles even though the underlying `rows` array had changed. The fix keeps
exactly **one** stable identity: `ForEach(..., id: \.element.id)` and
`.id(row.id)` on the row (not `.id(index)`), with the `ScrollViewReader`
scroll target keyed to `rows[newValue].id` to match. Rule: never combine a
positional `.id(index)` with an element-identity `ForEach` on the same node
tree — pick one identity source and use it for both diffing and
`scrollTo`.

**2. Stale staged-binary trap during manual verification.**
`./script/build_and_run.sh` builds the GUI/CLI products *and* stages the
result into `dist/Rafu.app` (see
[`build-and-run.md`](build-and-run.md)). Running a bare `swift build` and
then `open dist/Rafu.app` (or launching the `dist` binary directly) runs the
**previously staged** bundle, not the just-built one — so a real code fix
appears to "not work" during manual testing. Rule: always re-run
`./script/build_and_run.sh` (which re-stages) before manually exercising GUI
behavior after a source change; never trust `open dist/Rafu.app` as
evidence following a bare `swift build`. This caused a lengthy false-negative
detour while diagnosing the palette rendering bug above, because the stale
binary reproduced the *old* buggy behavior after the fix already landed in
source.

**3. File-index error-path latching.** `WorkspaceFileNameIndex.build`'s
`catch` path used to set `state = .ready(count: 0, isTruncated: false)` on a
failed `git ls-files`/enumerator run. `WorkspaceSession.ensureFileIndexReady`
only triggers a rebuild when the index is `.idle` — a `.ready(count: 0)`
state (even though it came from a failure) reads as "successfully indexed,
zero files" and is never retried, permanently pinning ⌘P's file mode at "no
matching files" until the workspace is reopened. Fix: the `catch` path resets
`state = .idle` instead, so the next `ensureFileIndexReady()` call retries
the build. Separately, the palette's file-mode query gained an explicit
~110ms debounce (`CommandPaletteView.queryDebounce = Duration.milliseconds(110)`)
so each keystroke's `.task(id:)` cancels the previous in-flight rank instead
of racing it.

## Why it matters

All three failure modes present identically from the user's chair —
"search doesn't find the right thing" or "search is empty" — but have
unrelated fixes (a `ForEach` identity rule, a manual-testing procedure, and
an actor state-machine bug). Misattributing one for another wastes a full
debugging pass; a fix landed in source can look ineffective purely because
of pitfall 2.

## Reproduction or evidence

- Pitfall 1: open the command palette, type a query that matches N results,
  then a different query that also matches N results but different files —
  without the fix, the visible rows/titles do not update even though
  `rows` did.
- Pitfall 2: edit any GUI source file, run only `swift build`, then `open
  dist/Rafu.app` — the running app still exhibits pre-edit behavior.
- Pitfall 3: force a `git ls-files`/enumerator failure (e.g. corrupt a
  workspace mid-index-build) and confirm ⌘P's file mode stays empty forever
  afterward without the `.idle` reset.

## Verification

```bash
swift build
swift test   # SearchCommandPaletteTests, WorkspaceFileNameIndexTests
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify   # always re-stage before manual GUI checks
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Views/CommandPaletteView.swift` (`resultsList`, `queryDebounce`)
- `Sources/RafuApp/Services/WorkspaceFileNameIndex.swift` (`build`)
- `Tests/RafuAppTests/SearchCommandPaletteTests.swift`
- `Tests/RafuAppTests/WorkspaceFileNameIndexTests.swift`
- [`build-and-run.md`](build-and-run.md)
- [`memory-and-file-indexing.md`](memory-and-file-indexing.md)
- `docs/plans/phases/pre-initial-push-workbench.md`
