# Canvas native boundaries and initial evidence

- Applies to: ADR 0025 and Canvas C0–C5; local macOS workspaces.
- Verified: 2026-10-18, macOS 27.0.1, Apple Swift 6.4, Swift 6.2 package mode,
  strict concurrency, arm64, deployment target macOS 15.

## Rules and observations

C0's three native boundary tests pass without starting a shell, browser load,
external app, or screen capture. One `RafuTerminalView` moved between NSWindows
retains the same parser and negotiated keyboard state. The newline monitor has
one registration while attached and none after detach. This proves native view
transfer only; controller/PTY identity and focus across real Canvas tabs are C3 checks.

ScreenCaptureKit accepts a single-window picker configuration and bounded stream
configuration (960×540, three queued buffers, 10 fps, audio disabled). The Swift
SDK imports `SCContentSharingPickerConfiguration` as a value: bind it with `var`
before setting `allowedPickerModes`. The Objective-C header's class declaration
is not the complete Swift API. These configuration probes do not prove permission,
source-loss, or live stream behavior; C4/C5 use the visible controls for those checks.

A WebKit configuration accepts a nonpersistent data store, disables automatic
JavaScript windows, and requires user action for media playback. No WKWebView or
network request is created by the probe. Actual lifetime and navigation are C4 checks.

Do not infer performance, idle memory, compatibility with untested OS versions,
or permission success from these results. The package still targets macOS 15;
this machine supplies runtime evidence for macOS 27 only.

## Reproduction

```sh
./script/test.sh --filter CanvasFeasibilityTests
./script/test.sh --filter 'Canvas(Document|Persistence|Feasibility)Tests'
```

C0: 3 tests passed. Initial domain/store checkpoint: 11 tests in 3 suites passed,
including parameterized URL checks, stale write detection across two store
instances, corruption isolation, capacity, and payload bounds. Logs are retained
in `/tmp/rafu-canvas-implementation-20261017/` for this local session.

## Persistence boundary

The default Canvas directory uses `RafuAppIdentity.current.applicationSupportRoot()`.
Release and Lightning records remain separate. The app state-root source guard
also applies to new stores; a store must not build its own Rafu root path.

`CanvasPersistenceStore` runs file reads, validation, and encoding on an actor.
The shared instance serializes windows; a nonblocking advisory file lock covers
cooperating app instances. It validates the expected revision before atomic
replacement and uses UUID-only filenames under a workspace digest directory.
Reads reject symlinks/nonregular files and read at most the 2 MiB cap plus one
byte. Corrupt boards are reported separately from valid siblings. No source
file, command, terminal output, credential, cookie, or captured frame is stored.

Related: `Sources/RafuApp/Canvas/`, `Tests/RafuAppTests/Canvas/`, ADR 0025,
`docs/plans/phases/workspace-canvas.md`, ADR 0023 and 0024.

## C2–C4 integration review

The typed `.canvas(CanvasID)` resource enters the existing editor layout. Only
IDs of separately saved boards enter workspace metadata. A missing board record
is dropped without starting a resource. Canvas does not replace the existing
source-file TextKit owners. Native note owners provide bounded snapshots to the
atomic Canvas store; their live strings stay outside Observation.

`NativeContentMount` returns a distinct NSView per presentation. A terminal lease
checks the current window owner before attaching and before a queued responder
request. Late teardown detaches only a view still parented by that container.
Terminal cards use existing controllers and process limits. New cards hold inert
ordinary-shell records; Start remains a separate action. Agent/Ensemble records
restore as unavailable placeholders. No terminal output, commands, credentials,
environment, or process identity enters the Canvas record.

Images reserve an 8 MiB window budget before decode. Thumbnail and focus decode
dimensions are bounded. There is no persistent offscreen image cache.

Web controllers are created as metadata, with WKWebView created only by Connect.
Each uses a nonpersistent store. Main-frame navigation and response redirects
must remain on the selected origin. External links need Open Link in Browser.
Downloads, popups, auth injection, certificate bypass and native bridges are not
provided. Media playback needs a user action. Web subresources can contact
external services; Connect explains this. Hiding the board destroys its web
views. Restoring a board makes no web request.

Native app references use bundle identifiers. Open App activates a separate app.
Choose Window uses the ScreenCaptureKit single-window picker. A shared broker
holds only one pending selection. Frames use one bufferingNewest(1) channel,
960 by 540 pixels, 10 fps and three queued buffers. There is no audio, recording,
OCR, synthetic input, or transmission to an agent. Source loss, hidden cards,
window occlusion, screen lock, and board close stop the preview. No automatic
resume follows unlock or restoration.

### SDK compatibility exception

The macOS 27 ScreenCaptureKit SDK does not give the picker observer parameters a
Swift actor or Sendable contract. `SCContentFilter` has mutable SDK properties
and cannot honestly be declared Sendable. The native pass verified that the
picker can deliver its selected filter off main. A main-thread-only guard made
preview unavailable and was removed.

The adapter uses a file-scoped `@preconcurrency import ScreenCaptureKit` for one
handoff of the exact picked filter into a MainActor task. Rafu never mutates the
filter or exposes it outside capture setup. Stream construction and lifetime
control remain on MainActor. No broad `SCShareableContent` inventory, replacement
filter, unsafe wrapper, or new Sendable conformance is used. This is an explicit
legacy SDK interoperability assumption, not compiler proof that the framework
has no other references. Astra Medium reviewed this boundary. Full compilation
passes with no new source warnings; `swiftc -typecheck` alone is insufficient
because it does not run the SIL region-isolation diagnostics.

A separate `Mutex<UUID?>` holds only a request ticket. Each terminal picker
callback snapshots its ticket before the actor hop and consumes only a matching
ticket. Cancelling an owner clears the weak owner but leaves the request occupied
until the SDK sends its terminal callback. This prevents both queued callback
handoffs and late SDK callbacks from being assigned to a new card. The filter
never enters the lock. A cancelled request cannot start a stream. New selection
waits for the outstanding system picker to finish; there is no timed polling.

Apple's [picker observer contract](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickerobserver)
describes selection, cancellation, and start-failure callbacks. It does not
promise a callback queue. Recheck this adapter when the SDK adds concurrency
annotations.

WebKit navigation-delegate completion blocks carry their exact MainActor and
Sendable annotations. An unannotated block can compile as a nearly matching
optional requirement and fail to install the intended navigation policy. The
build must have no such warnings.

The window-close proxy forwards typed NSWindowDelegate callbacks on MainActor.
Its nonisolated responds(to:) returns only a Bool through assumeIsolated and
reports each optional wrapper only when the original delegate implements it.
The original delegate is restored when the guard detaches. No unmanaged pointer,
unchecked Sendable conformance, or new package target is needed. A failed Canvas
save cancels window close/app quit. Workspace replacement flushes Canvas content
before it changes the descriptor.

## Integration verification checkpoint

Verified on macOS 27.0.1 (26A434), Apple Swift 6.4, arm64, with the macOS 15
package deployment target. The integrated code passed build, 2,306 tests in
parallel (47.285 seconds for the 2,240 app tests) and serial (111.675 seconds for
the app tests), plus canonical Rafu Lightning launch verification. The other
66 tests are in the CLI target. These results do not establish runtime behavior
on macOS 15 or Release performance. Final handoff repeats the gates after the
documentation and note text-size update.

The first broad run found two source presentation-contract failures and a
regular Terminal Group duplicate-record diagnostic regression. The source was
fixed; none of those tests were changed or disabled. Canvas now has its own tab
component using the same attached cap and close control. Ordinary saved groups
restore before Canvas references are resolved, so duplicate regular records
still keep their diagnostic while a Canvas can share an accepted group.

Additional regression coverage includes scoped file reads, nonblocking rejection
of special files, 8 KiB text previews, bounded 8-bit RGBA image decode, image
reservation release after failure, a 100-card/200-connection layout with undo,
background tab close, and keeping Start Pane inside Canvas. The 100-card model
test is a correctness check. It does not measure rendered frame latency.

Editor-layout schema 2 accepts schema 1. A malformed optional layout or excessive
Canvas-ID list cannot discard the workspace or its independently saved files.
Notes use native TextKit 2, native undo, and scaled body text. Native note and web
mounts check the current presentation identity so a late old host cannot reclaim
a view after a split move.

Two close rules are required. Set the teardown guard before adapter cleanup,
because parking a group can request persistence and cancel a pending close
save. Freeze the accepted Canvas resource snapshot before the terminal manager
is emptied, so a later quit flush cannot erase inert terminal profiles. Quit
also repeats actual saves when edits arrive during awaited metadata writes; it
replies only after a synchronous check sees stable metadata and no pending
Canvas content. This loop does no timed polling. A failed save shows the affected
Canvas and cancels close or quit. Tests cover each case without fixed sleeps.

Window occlusion and lock stop previews. Visibility or unlock only permits a new
explicit request; it does not restart a web load or capture. Distributed lock
notifications are treated as platform behavior to verify in the native pass;
ScreenCaptureKit blank/suspended/stopped frames also end the stream. Keep the
window-delegate forwarding list in step with SDK changes when the toolchain is
updated.

## Native UI pass after unlock

The native pass used the staged Lightning bundle and disposable files under
`/tmp/rafu-followup-20261017/fixtures`. It verified:

- Canvas creation, native note input, Save, and note restoration after relaunch.
- Full board layout after the empty-editor overlay repair, Arrange and Fit All,
  and the accessible Cards/Relationships list. Selecting a card now gives the
  board keyboard focus. Right Arrow changed the saved x position from 40 to 50;
  Command-Z restored 40, and Return opened the selected card's focus surface.
- Explicit stopped-terminal Start, native input and output, and inert terminal
  restoration after relaunch. A raw terminal input probe received `0a 0a` from
  Control-Return and Shift-Return. The test shell was then exited.
- Local web Connect, editable input and a working test button at an isolated
  loopback fixture. Leave Content unloaded the page and showed the explicit
  Connect action again.
- A second workspace window opened the same fixture without inheriting the
  first window's Canvas tab. Closing it left the first board in place.
- Single-click source opening, dirty text across Canvas/Settings switches, and
  the same native Undo operation after returning to the source editor.
- Native app reference selection through NSOpenPanel and visible app controls
  after the empty-content lifecycle repair. The user selected a window through
  the system picker. Its frame appeared with Live Preview state. Switching to
  Settings stopped capture; returning to Canvas showed Paused and Choose Window,
  with no automatic resume. This verifies one stream on this host, not the full
  source-loss or permission matrix.

Two SwiftUI rules were verified by the native pass and a hosted-view regression:
An overlay receives its base view's size, so the editor group must claim its
GeometryReader size before adding Canvas or Settings overlays. A lifecycle hook
on an empty conditional Group need not run; native app cards keep a real VStack
and a preparation state before installing their metadata controller. App
metadata creation starts no capture. Menu controls use their intrinsic width.
Card header/summary selection and header drag explicitly focus the board; a
selection value alone does not make SwiftUI deliver keyboard movement events.
To repeat this focus regression, click a card header, press Right Arrow, save,
undo with Command-Z, and press Return. Check position and the focus surface.

Source loss, denial/revocation, lock/unlock, the full accessibility
settings matrix, sustained terminal input, and Instruments memory/frame/typing
measurements remain separate checks. Do not count a launch, an accessible tree,
or a status-bar memory value as that evidence. No Release app was built or
launched. Use the existing project policy for any later Release measurement
allowance. UI-fix gate logs are stored under
`/tmp/rafu-canvas-implementation-20261017/`.

## Direct input correction, 2026-10-18

Applies to the Canvas board on the same macOS 27 / Swift 6.4 host above.
The board's optional Space-drag gesture must use the `.subviews` mask when
Space is up. Using `.none` disables child gestures too, including background
and card drags. The native pass reproduced and repaired the fault: dragging
empty space moved all cards; dragging a title moved only that card. Summary
drags use the same transaction, while a click enters content. Note summaries
do not select text; native note editing remains available in focus mode.

The editor overlay must identify each WorkspaceCanvasView by board ID.
Without that identity, switching between two Canvas tabs reuses local view
state without installing the new board's presentation owner. Focus can then
show a blank note or reject a terminal lease. A hosted-view regression switches
between two boards and checks presentation ownership.

Repeat with `./script/test.sh --filter 'Canvas(BoardState|Integration)Tests'`
and the canonical Lightning launch. In a disposable board, drag empty space,
drag a card title and summary, undo, click once to focus, and type in a note
or an explicitly started terminal. Switch to a second Canvas and back.
Focus alone must not start a shell, load a web page, or capture a window.
Related: ADR 0025 and `docs/plans/phases/workspace-canvas.md`.

The direct-input pass also found that a note's first representable update can
occur before its mount has a window. NativeContentMount now exposes a narrow
window-attachment callback, cleared on detach. The note requests first responder
only for its current presentation and only while content is active. The pass
verified one-click note typing and native undo, one-click stopped-terminal
controls, explicit Start followed by shell output, and one-click input after
switching Canvas tabs. The test shell was exited. No new process, file-write,
capture, or network authority was added.

## Inline cards, 2026-10-18

The user's later correction supersedes the separate 100% focus surface described
in the earlier evidence. Terminals, local web apps, and active notes now mount
inside board cards. New terminal cards are single terminals. One-pane internal
group records retain the existing process/restoration boundary; Canvas adds no
new runtime owner. Group splits are disabled from Canvas. Four terminal surface
leases and two loaded web views remain the per-window limits.

Focus changes and Leave Content now release keyboard focus without unloading
other visible cards. Hiding/closing the Canvas still stops web/capture resources
and parks terminals. A native web mount uses a window-scoped mouse-down observer
to update card focus while leaving the event intact for WebKit. Its observer is
removed on detach. No synthetic input or cross-process event forwarding is used.

SwiftUI board key handlers must return ignored while card content is active.
Without this guard, the focusable ancestor consumes Space, Return, Delete, and
arrow keys before the native terminal can use them. Background wheel handling
also excludes the active card body. Header dragging and the corner resize handle
keep separate layout gestures.

The native pass on macOS 27 / Swift 6.4 verified:
- Shell input containing spaces and Return produced "inline terminal ok".
- A corner resize changed the PTY from 9 rows × 45 columns to 15 × 50.
- Board zoom from 95% to 79% retained 15 × 50.
- A local web card resized while its terminal neighbour remained visible.
  Its input accepted "Inline app input works"; its button showed
  "Local interaction passed".
- Add Card offers Terminal directly, and a second stopped terminal card can
  be started without adding group chrome or replacing the board.

These are functional checks, not frame-time or sustained-input measurements.
The full accessibility/performance and native capture matrix above remains open.
Build/test logs for this pass use the /tmp/rafu-inline-* prefix.

## File drops and node closing

Sidebar file drags advertise both the private editor drag type and a file URL.
When Canvas is selected, the enclosing editor body must stop accepting those
types. Otherwise its editor-navigation drop handler competes with the Canvas
file-node destination. The tab strip keeps its independent drop handling.
See `EditorCanvasView` and `WorkspaceSidebarView` for the two boundaries.
The Canvas destination uses the editor's explicit copy proposal and reads the
private file payload before the public file URL. Automated sidebar drags had no
visible result with either the URL-only Transferable handler or the explicit
delegate. The source/destination cause is not established; manual verification
remains open. Tab payloads are rejected; asynchronous URL batches preserve
source order and fail as a whole when any provider fails to supply a valid URL.
The incoming provider is the source of file identity. Do not use the destination
session's `activeEditorDrag` cache: cancellation can leave it stale, and a drag
from another window updates the source session only.

Canvas drops validate regular files off the main actor, then append the whole
batch in one undo transaction. Coordinates subtract viewport translation and
divide by zoom. The current schema accepts workspace-relative files only;
outside files and directories are rejected without a partial insertion.

Command-Shift-W removes selected reference nodes immediately and supports undo.
It does not delete source files. Terminals and nonempty note snapshots keep the
existing confirmation because they have process or content state.
The native check added First.swift through Add Card and confirmed that
Command-Shift-W removed the node while First.swift remained in the sidebar.

Check with `./script/test.sh --filter CanvasNodeInteractionTests`, then drag a
sidebar file onto the running Canvas and close it with Command-Shift-W. Check
that the node disappears and the source stays in the sidebar. These additions
change input routing, not the existing native capture or performance claims.
