# Workspace navigation and restoration scheduling

- Applies to: local CLI line/column navigation, workspace bookmarks, state saves,
  and window close.
- Integration environment: Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.0.1
  (26A434), 2026-10-17. The integrated build and focused regression checks pass.
  Final full-suite results and UI limits are recorded in the repair handoff.
  These checks do not establish a runtime speed gain or release memory budget.

## Rule

Use `WorkspaceFileService.readText` for an unmounted file's navigation read.
`WorkspaceLocationLoader` keeps both that read and the line/column scan off the
main actor. The same UTF-8, regular-file, and 16 MiB checks apply as for editor
loading. Navigation does not write the file. A mounted live buffer or transient
dirty text takes precedence. Check available live text again after the async
read, including a clean buffer that loaded while the read was in progress.

Cancel a pending request when another request, tab selection, workspace change,
or window close occurs. Check the request identity, workspace root, document
identity, and selected document before applying the result. Selecting away and
back must not make an old request valid again. Also compare the current caret
range with its value at request time (or the retained/default initial range for
an unmounted editor). A changed range rejects the result. This range comparison
cannot detect movement away and back to the identical range; complete event
history would need a selection generation from the editor boundary.

Find can attach before the editor's async load ends. An unmounted editor needs
its resolved range in both Find state and `restoredSelection`. A loaded editor
needs only the Find selection; leaving an extra restored selection there can
apply an old caret on a later reload. A clean newly mounted editor can expose an
empty snapshot before loading. Resolve that case asynchronously.

Combine ordinary state changes for 200 ms before building layout and inert
Terminal Group metadata. Keep only one cached bookmark, keyed by the workspace
URL and authorization identity. A new folder authorization invalidates the key,
even for the same path. Cache a restored bookmark only if resolution reports it
as current. A stale bookmark must be regenerated under the granted access.

`WorkspaceRestorationStore` owns its cache and synchronous encoding/defaults
operations on its actor. It replaces one complete encoded metadata value and
checks cancellation before replacement. There is no suspension within a write.
The existing restoration schema and tolerant Terminal Group decode remain in
use. No text, output, command, credential, or live process is added to the data.

Capture final state before terminal teardown removes saved group metadata.
`flushWorkspaceState()` bypasses the delay and returns an awaitable task that
retains value metadata and the store, without retaining the session. The save
holds its own balanced security scope, so a rapid close cannot release folder
access before the first bookmark is made. Use the session's original
`securityScopedURL` for both that access and bookmark creation. The descriptor's
reconstructed `rootURL` preserves the path but does not preserve the granted URL
capability. Use it only when the session has no granted URL. Repeated terminal teardown does not
cancel that final task. App termination must await the returned task before it
allows the process to exit; an `applicationWillTerminate` callback alone is too
late to await asynchronous work. `RafuAppDelegate.applicationShouldTerminate`
returns `.terminateLater` and uses `WorkspaceTerminationPersistence` to reply
after the saves finish. Repeated pending requests share one task and one reply.
The existing registry supplies key-window-first order; saves run sequentially in
reverse order so the one-workspace preference ends with the key workspace.
`WorkspaceCloseSaveTracker` retains pending close-save tasks independently of
the window registry. Quit enters a barrier synchronously before creating its
async task. A close registered during quit is cancelled on the main actor before
its task can start bookmark or preference work. Explicit ordered quit saves are
permitted. Quit drains older close tasks before saving live windows and keeps
the barrier active through the AppKit reply. If the reply returns without a
process exit, the barrier is released so normal close saves can resume.

The tracker also checks close registrations around the final key-window save. If a close arrives
during that save, it drains that work and reapplies the key-window state. A
registration identity detects even a close that finished and was removed while
the key-window save was suspended. These waits consume actual tasks, with no
timers or status polling. No window registry change is required.

The injected bookmark maker can suspend for deterministic tests. Check
cancellation after it returns and compare its cache generation before storing
its result. Cache reset or reauthorization can occur across that suspension.

The metadata save does not invoke document save or close actions, change dirty
flags, or dismiss an existing close/quit confirmation. At this checkpoint,
Rafu's dirty-file review applies to tab close; there is no app-wide dirty-file
review in the existing app delegate. This repair preserves those controls and
does not add an automatic save of unsaved text.

## Why this matters

A cancelled task can still finish its file read. Without identity and dirty-state
checks, it can apply a disk offset to a newer buffer or take selection after a
new navigation action. Rebuilding bookmarks and layout values for every tab
change repeats work. Cancelling the final save during deinitialization loses the
latest state. Releasing security scope before bookmark creation can also prevent
that save.

## Evidence and reproduction

`WorkspaceNavigationRestorationRepairTests` adds cases for async CRLF selection,
transient dirty text, dirty text after a request, stale selection, newer goto,
invalid UTF-8, authorization-keyed bookmarks, restored bookmark renewal, final
flush, combined state updates, cancelled writes, and cross-group edge drops.
`WorkspaceTerminationPersistenceRepairTests` adds key-workspace-last ordering,
one reply for a duplicate request, a later request cycle, and preservation of
dirty text and confirmation state. `WorkspaceCloseSaveOrderingRepairTests`
adds a delayed closed-window bookmark on a separate store actor sharing the
same preference domain, a new close during the blocked key-window save, release
of the quit barrier after a simulated reply, and a close completed during a
final-save callback. Those ordering tests await explicit stream signals and task
completion. The late-close case checks both reply timing and the saved root.
These tests pass in the integration checkout. They use unique
defaults suites, no terminal process, and await task completion without fixed
test sleeps.

The existing `WorkspaceGotoLocationTests` disk and hibernation cases now await
the task returned by `openFile(atRelativePath:selecting:)`. Their range assertions
remain. Their fixture now uses a unique defaults suite so an async test cannot
change the user's saved workspace.

The first central test compile exposed a Swift Testing macro constraint:
`#require(layout.split(...))` tries to call the mutating method on an immutable
macro parameter. Run the mutation first, store its optional result, then pass
that result to `#require`. The reported compiler errors were corrected and
the integrated build and focused tests pass.

A separate navigation read and editor read can still occur for an unmounted
file. This change removes synchronous navigation I/O; it does not claim that
those reads are shared or that runtime performance budgets have passed.

## Verification commands

```sh
swift format lint --strict Sources/RafuApp/Models/WorkspaceSession.swift Sources/RafuApp/Services/WorkspaceRestorationStore.swift Sources/RafuApp/Services/WorkspaceLocationLoader.swift Tests/RafuAppTests/WorkspaceNavigationRestorationRepairTests.swift
swiftc -frontend -parse Sources/RafuApp/Models/WorkspaceSession.swift Sources/RafuApp/Services/WorkspaceRestorationStore.swift Sources/RafuApp/Services/WorkspaceLocationLoader.swift Tests/RafuAppTests/WorkspaceNavigationRestorationRepairTests.swift
./script/test.sh --filter WorkspaceNavigationRestorationRepairTests
./script/test.sh --filter WorkspaceGotoLocationTests
./script/test.sh --filter WorkspaceTerminationPersistenceRepairTests
./script/test.sh --filter WorkspaceCloseSaveOrderingRepairTests
./script/test.sh
./script/test.sh --no-parallel
```

Run build and test commands only in the assigned machine slot. GUI acceptance is
for the user: check a goto during load, unsaved text, a second window, rapid tab
changes followed by window close, permission renewal, and app quit/reopen. Do not
infer speed or resource use from the source change.

## Related code and decisions

- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Services/WorkspaceRestorationStore.swift`
- `Sources/RafuApp/Services/WorkspaceLocationLoader.swift`
- `Sources/RafuApp/Editor/CodeEditorView.swift` (`load` and `restoreViewState`)
- `Sources/RafuApp/App/ExternalOpenRequests.swift` (termination integration)
- `Sources/RafuApp/Services/WorkspaceTerminationPersistence.swift`
- `Sources/RafuApp/Services/WorkspaceCloseSaveTracker.swift`
- `docs/references/editor-search-and-restoration.md`
- `docs/references/cli-app-ipc.md`
- ADR 0006: bounded editor working set and dirty-text handoff
- ADR 0023: inert Terminal Group restoration
- `docs/plans/phases/pre-initial-push-workbench.md`
- `docs/plans/phases/editor-performance-repair.md`
