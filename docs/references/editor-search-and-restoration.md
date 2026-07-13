# Editor search and restoration

- Applies to: file find/replace, workspace search/replace, undo, editor groups, and restoration
- Last verified: Swift 6.2, AppKit/TextKit on macOS, 2026-07-13

## Rule or observed behavior

- Resolve enumerated filesystem URLs before subtracting a resolved root path.
  macOS temporary paths commonly present `/var/...` while resolving to
  `/private/var/...`; mixing them duplicates a root suffix and produces missing
  files. Return result URLs rebased onto the user-selected presentation root.
- Workspace replacements require a preview with content fingerprint, byte count,
  and modification date. Re-read and revalidate every file before atomic writes;
  refuse dirty open buffers and stale previews.
- When `UndoManager.groupsByEvent` is disabled for deterministic replace-all,
  call `setActionName` before ending the explicit undo group. Naming a closed
  group triggers an AppKit invalid-group exception.
- Persist recursive editor layout behind a schema version. On restoration, rebase
  saved file URLs from the saved root onto the resolved security-scoped root,
  remove missing/out-of-workspace tabs, and collapse empty groups.
- Keep live text in `NSTextStorage`. Find models store only queries, options,
  ranges, counts, and small previews.

## Why it matters

Path aliases otherwise make valid search results fail only in temporary folders
or particular volumes. Replacement and restoration cross time and external file
changes, so stale state must never silently overwrite data or reopen paths outside
the granted workspace.

## Reproduction or evidence

Focused tests use symlinked temporary roots, binary/ignored files, bounded result
sets, regex capture replacement, stale previews, explicit TextKit undo groups,
recursive split round trips, and unsupported restoration schema versions.

## Verification

Run `swift test --filter Search`, `swift test --filter Editor`, then the full
`swift test` suite. The manual pass must cover find focus/undo, a stale replace
preview, multiple split axes, and reopen after moving the Navigator.

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/`
- `Sources/RafuApp/Search/`
- `Sources/RafuApp/Services/WorkspaceRestorationStore.swift`
- `docs/decisions/0002-native-workbench-navigation.md`
- `docs/plans/phases/pre-initial-push-workbench.md`

