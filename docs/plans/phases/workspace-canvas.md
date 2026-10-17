# Workspace Canvas and app cards

- Status: Implementation authorized, 2026-10-17. Sequential execution in the primary checkout; local commits only. ADR 0025 records the accepted scope.
- Date: 2026-10-17.
- Request: a spatial workspace based on the supplied Maestri image, including native macOS app windows.
- Reference: https://cdn.maestri.dev/assets/feature-canvas.png
- Related: ADR 0002, 0006, 0018, 0019, 0020, 0023, 0024; the active pre-initial-push workbench phase.

## Active execution override

The user authorized a baseline commit and implementation of the approved Canvas
scope. Baseline: `0c4db05`. Use one agent and one checkout in C0–C5 order. Do not
create implementation subagents or worktrees. The nine worktree assignments in
the earlier execution proposal are now historical workstream boundaries; their
path and validation contracts still guide the sequential stages. Only consult
Astra at Medium if genuinely needed. No application push or release is authorized.

Progress:

- Baseline `0c4db05`: repairs and planning sources committed; format, build,
  2,273 parallel/serial tests, canonical Lightning launch verified. The known
  Ensemble status test passed alone and serially after a parallel load failure.
- C0 SDK/native view probes: 3 tests pass. Live permission and source-loss checks
  remain C4/C5 checks through visible controls. See `canvas-native-boundaries.md`.
- Foundation `165a85d`: bounded schema, native boundary probes, board transactions,
  atomic per-variant store, and window-store tests committed. Build, 2,290 tests
  in parallel/serial modes, and canonical Lightning launch passed.
- C1–C4 code is implemented: typed tabs, board controls, native notes,
  file/image cards, terminal presentation leases, local web views, and native app
  previews. The integrated code passed 2,306 parallel and serial tests plus the
  canonical Lightning launch. The UI repairs use a final format, lint, build,
  parallel, and serial gate sequence before the local checkpoint commit.
- C5 native checks resumed after unlock. Notes/save/reopen, a stopped terminal,
  modified Return bytes, live loopback web input/unload, a second window, and
  source undo across Canvas/Settings passed. The pass found and repaired an
  empty-editor overlay size fault, blank native app card setup, card selection
  keyboard focus, and the picker callback's off-main handoff. Hosted-view and picker-ticket regressions cover
  the repairs. A user-selected live window preview displayed a frame and stopped
  on a Settings switch, with no automatic resume. Source-loss/permission and
  lock checks, the full accessibility matrix, sustained input and active
  performance measurements remain open. No Release
  launch was performed. See `canvas-native-boundaries.md` for evidence and limits.

## Intended experience

### Visual review

The [Execution and Worktree Plan](../wireframes/workspace-canvas/execution-plan.mdx)
defines baseline protection, nine staged worktree assignments, shared-file
ownership, fixed-SHA dependencies, review gates, and integration order for C0–C5.
It is distinct from the earlier eight-worktree performance/UI repair effort.
Its [rendered page](../wireframes/workspace-canvas/execution-plan.plan.html) is
also published on the existing private planning site. These are future
assignments from the earlier planning request. The sequential override above is now authoritative.

The [Visual Plan source](../wireframes/workspace-canvas/canvas-plan.mdx),
[rendered plan](../wireframes/workspace-canvas/canvas-plan.plan.html), and
[clickable wireframe](../wireframes/workspace-canvas/prototype.html) show the
proposed layout and transitions. See the
[review guide](../wireframes/workspace-canvas/README.md) for controls, simulated
behavior, verification, and design questions. These artifacts do not implement
Canvas in Rafu or accept a new architecture decision.

Open a named **Canvas** as a peer of file and Terminal Group tabs. Arrange the
parts of one task on a large two-dimensional board: agent terminals, a running
app, a design image, files, notes, and labeled connections. Keep the Files
Navigator and normal file editing available. A Canvas is optional and belongs
to one workspace window. It does not replace the editor or the Ensemble graph.

Example: create “Checkout flow”; place a Claude Code terminal on the left, the
local checkout web app in the middle, a native Simulator app card on the right,
and a Markdown checklist below. Connect the checklist to the relevant file.
A connection means “related to”; it never sends a prompt, starts a process,
executes a workflow, or grants an agent access to an app.

The reference image establishes the visual direction: movable cards on a quiet
grid, spatial grouping, notes, connections, and zoom. It does not establish the
other product's ownership, app embedding, persistence, or security behavior.

## Proposed first release

| Card | First-release behavior | Explicit action that starts work |
|---|---|---|
| Terminal Group | Live native SwiftTerm group; reuse existing controllers, pane identity, attention, and close rules | Start a stopped group, or choose an existing group |
| File | Title, path, type, dirty state, and a bounded preview; Open uses the existing document/editor | Open the file in its normal editor tab |
| Note | Small plain-text or Markdown note with native editing and native preview | Edit the note |
| Image | Bounded thumbnail from an explicitly selected workspace file | Open in the existing media viewer |
| Local web app | Interactive browser card for a user-entered loopback URL | Connect to the selected origin; Rafu does not start a dev server |
| Native macOS app | App identity plus optional user-selected window preview; Open App switches to the actual app | Choose Window to start preview, or Open App to activate/launch |
| Connection | Labeled line between cards, with accessible text equivalent | Add or edit the relationship |

Use existing Indigo/Khadi and theme tokens. Keep card headers opaque and clear.
Show focus, stopped state, errors, and attention with text and symbols as well
as color. Native web and terminal content keeps its own input behavior.

## Native app windows: capability and limit

This request includes native macOS windows, not only websites. Plan for two
levels that use public APIs:

1. **App reference:** save the bundle identifier and an explicit user label.
   Open App uses NSWorkspace/NSRunningApplication. No screen access is needed.
   Activation brings the app forward; do not promise selection of an exact
   foreign window without a separate verified capability.
2. **Optional live window preview:** the user selects one window through the
   ScreenCaptureKit system picker. Show its frames in a card, with clear
   Preview/Paused/Unavailable state and a visible Stop Preview action. The
   actual app remains an independent process and window. Keyboard and pointer
   input go to that app after Open App, not into a picture of its window.

ScreenCaptureKit supplies captured frames; it does not embed another process's
NSView or provide remote input. Do not describe this as an embedded native app.
Do not reparent foreign windows through private WindowServer APIs. Do not add
synthetic input or request Accessibility access as part of ordinary preview.
If exact-window raising is later required, evaluate an explicit Accessibility
feature separately. Closing a card never closes or terminates the other app.

The first engineering spike must prove selection, app activation, denial,
revocation, closed/minimized windows, display changes, and cancellation on the
supported macOS versions. If capture is unavailable, the useful App reference
card still works. This plan does not request screen permission now.

## Interaction contract

- New Canvas, Add Card, Fit All, Actual Size, Zoom In/Out, and Arrange have
  visible, menu, and command-palette paths. Canvas receives one Control-Tab entry.
- Scroll/pinch over board background pans/zooms. Scroll over an active terminal
  or web card belongs to that content. Space-drag pans only in board mode,
  never while entering terminal, web, or note text.
- Single click selects a card; a header drag moves it. Selection does not start
  a process, web load, capture, or another app. A clear Enter Content action
  gives keyboard focus to interactive content. Escape returns focus to the
  card shell when not consumed by that content; a visible Leave Content button
  and a dedicated menu action always provide an exit path.
- Board mode supports range selection, arrow-key movement, snapping, alignment,
  and undo/redo. Arrange changes layout only. Connect mode has a visible state;
  ordinary drags never create connections.
- The MVP does not edit source files in scaled miniature editors. Open File
  brings forward the existing editor, with the same dirty text and undo stack.
- At readable scale, terminals and web cards can be interactive. At overview
  scale, use summaries or bounded ephemeral frames and open the selected card
  in a 1:1 focus surface. Zoom must not repeatedly change terminal row/column
  counts. A deliberate card resize changes PTY size once after a bounded update.
- Command routing follows an explicit board/content focus state. In terminal
  content, group split and pane-focus commands call the existing group verbs.
  Save saves the Canvas, not an arbitrary terminal session. Closing a focused
  terminal pane uses its existing confirmation; closing a Canvas parks its
  groups and stops its web/capture surfaces. Neither operation hides a process
  termination inside a generic Delete action.
- Removing a terminal card offers Park Group or Close Group; Close uses the
  existing live-process confirmation. Removing an app card stops its preview
  only. Removing a file/image reference never deletes the source file.
- Provide a **Canvas List** view with all cards and relationships in stable
  order. It supplies full keyboard and VoiceOver access without spatial aiming.
  A minimap is useful after core navigation; freehand drawing can follow later.

## Ownership and implementation boundaries

Proposed new directory: `Sources/RafuApp/Canvas/`. Keep public domain values
Sendable and independent of SwiftTerm, WebKit, ScreenCaptureKit, and NSView.
Suggested contracts:

- `CanvasID`, `CanvasCardID`, `CanvasConnectionID`: stable value identities.
- `CanvasDocument`: version, title, bounded card payloads, rectangles, z-order,
  relationships, and viewport. It contains no live app or terminal objects.
- `WorkspaceCanvasStore`: per-window selection, viewport and interaction state.
  Note editing keeps live text in a native text storage owner; observation
  exposes only identity, revision, dirty state, and selection metadata.
  The persisted CanvasDocument receives a bounded snapshot only for saving.
- `CanvasPersistenceStore`: cancellable, atomic, version-checked I/O off the
  main actor. Never read, encode, or sort a board in a SwiftUI body.
- `CanvasSurface`: SwiftUI composition and accessible controls; a narrow native
  viewport boundary if scroll, magnification, or hosted native input requires it.
- `CanvasSurfaceLease`: one visual owner for an existing terminal group. The
  canvas and its normal tab never mount the same NSView twice. Selecting the
  other surface transfers the lease; the inactive surface shows a Reveal action.
  It does not clone a controller, session, PTY, or undo history.
- `CanvasWebPreviewController`: lazy, bounded WebKit boundary for local apps.
- `CanvasNativeAppController`: app activation and separate cancellable capture
  lifecycle. No global active-app observer or background app inventory scan.

Reuse existing Terminal Group capacity and lifecycle verbs. Count canvas-hosted
sessions in the same ADR 0024 limits; never add another budget of 200 sessions.
Keep Ensemble run cards as references to existing run detail and the read-only
graph. Canvas relationships are not Ensemble dependency edges.

Integrate via a typed Canvas editor resource and explicit restoration version.
The existing ephemeral Settings/Ensemble auxiliary-tab list is not a persistence
store for user-authored boards. Shared `EditorLayout`, `WorkspaceSession`, command,
restoration, and index changes belong to one integration owner.

## Persistence and trust

Default storage is workspace-keyed Application Support, outside the repository.
Save layout, notes, safe workspace-relative file references, explicit labels,
app bundle identifiers, and approved local-preview destinations. Notes are
content and require atomic writes and recovery, not UserDefaults. External file
references require explicit selection and scoped bookmark rules.

A saved Canvas restores inertly. It starts zero shells, agents, servers, browser
loads, captures, or external apps. Ordinary terminal groups restore using the
existing safe profile rules. Agent/Ensemble groups restore as unavailable
placeholders where the existing contract requires it. Save no terminal output,
prompts, commands, environment, tokens, web cookies, captured app frames, PID,
foreign window ID, or inference capability. Capture selection is session-only.
Do not store URL credentials, query strings, or fragments by default. Explain
any sanitized destination before saving it.

A later explicit Export/Import action can provide a portable board package.
Import is bounded, validates all schema/ranges/IDs, and cannot start anything.
Do not add implicit `.rafu` repository writes in the MVP.

Local app preview accepts validated `http`/`https` loopback origins only in the
MVP. Parse URLs, reject credentials and unsupported schemes, and revalidate
redirects. Use an isolated nonpersistent web data store. No native script bridge,
file access, provider credential injection, shared browser profile, or automatic
certificate bypass. External top-level navigation opens in the user's browser
after a visible action. Subresources can still contact external services; show
that this is a live web app before Connect. New windows, downloads, clipboard,
media, and authentication require explicit product policies and tests.

Native window capture is local and ephemeral: no recording, audio, file export,
OCR, agent transmission, or background capture. Stop when its Canvas is hidden,
the window is locked, selection is revoked, or the source disappears. Never
silently switch to another window or the full display. User permission and
resource ownership must remain visible.

## Proposed resource budgets and evidence

These are design ceilings to validate, not measured performance claims:

- 10 saved/open Canvas documents per workspace window; 100 cards and 200
  connections per board; bounded note text (64 KiB each) and total payload (2 MiB).
- At most four visible live terminal card surfaces; this is a rendering limit,
  not a new process limit. Hidden running terminals remain in the bounded
  terminal manager and retain output draining; do not freeze their processes.
- At most two loaded local web preview controllers and two native capture
  streams per window. Show Paused cards when capacity is full. Start capture
  at 10 fps with a bounded resolution and queue; measure before raising it.
- Zero web/capture resources before explicit use. Pause/destroy hidden web
  surfaces and stop hidden capture. Images use bounded decode dimensions and
  a byte-budgeted cache. No full-resolution snapshot per offscreen card.
- Record idle Rafu memory before/after Canvas use and separate child WebKit
  processes. Preserve the existing roughly 150 MB idle-local target; establish
  a separate measured active-Canvas budget during the spike. Do not claim the
  idle target covers terminals, web apps, and capture simultaneously.
- Test pan/zoom at 100 cards, typing at four terminal surfaces, one long-running
  agent session, and repeated attach/detach. Measure p95 frame/typing latency
  with signposts and Instruments. Record allocations after all cards close.

## Delivery order and owned paths

| Step | Scope and likely ownership | Exit evidence |
|---|---|---|
| C0: feasibility | Isolated prototypes; native app capture/activation, native terminal zoom/focus/reparent, WebKit lifecycle | Input and resize work; denied permission fallback; resource measurements; no process restart |
| C1: decisions and contracts | Proposed ADR accepted; Canvas domain/store, typed editor resource, command/restoration seams | Schema bounds, migration, focus routing, zero-work restoration tests |
| C2: board foundation | Canvas viewport, cards, selection, pan/zoom, connections, list mode, persistence | Keyboard/VoiceOver, undo, save/reopen, two-window tests |
| C3: repository and terminal cards | File/image/note adapters; terminal lease and capacity adapters | Dirty file/undo preserved; no duplicate PTY; safe park/close; sustained typing |
| C4: app cards | Separate WebPreview and NativeApp adapters, permission/state UI | Loopback restrictions, live interaction, capture lifecycle, denial/revocation, bounded resources |
| C5: integration | One owner for shared files, docs, tests and launch | Full parallel + serial suites, native UI pass, privacy/security review, Release measurements under an explicit phase allowance |

Land shared contracts before splitting ownership of renderer/adapters. Do not
start worktree fan-out from the present uncommitted tree. No commit, push,
publish, dependency change, or app permission grant is part of this plan.

## Decisions required before implementation

Write a proposed ADR with these narrow changes. Keep it Proposed until the user
approves implementation and the C0 evidence supports the design:

1. Permit an optional spatial workspace alongside existing editor tabs.
2. Permit bounded WebKit use only for explicit local app previews. ADR 0019/0020
   and native Markdown/Mermaid remain unchanged for documents and diagrams.
3. Permit user-selected native window capture for ephemeral local previews.
4. Permit terminal presentation leases while keeping one terminal owner and the
   existing process, capacity, save, and restart contracts.
5. Accept the inert board format, proposed bounds, and explicit close semantics.

Do not silently supersede an accepted ADR in a phase plan. No extension host,
embedded agent, remote control service, arbitrary app plugin runtime, or
workflow execution through canvas connections is proposed.

## Acceptance scenario

Create a board with two terminals, a local web app, a native app card, one note,
and two files. Move, resize, connect, fit, and focus them using pointer and
keyboard. Switch repeatedly between Canvas, Settings, Ensemble, and file tabs.
Dirty text and undo survive. A terminal has one view owner and one process.
Close and reopen the board: layout and notes return; processes, web loads,
other apps, and capture do not start. Deny capture permission and continue using
the app reference. Close one Rafu window without changing another window's board
or terminating an external native app. Repeat with VoiceOver, Full Keyboard
Access, Reduce Motion, Increase Contrast, and reduced transparency.

## Sources and limits

- User-supplied [reference image](https://cdn.maestri.dev/assets/feature-canvas.png), visually reviewed 2026-10-17.
- Apple's [SCContentSharingPicker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker) supplies user-selected capture.
- Apple's [ScreenCaptureKit overview](https://developer.apple.com/videos/play/wwdc2023/10136/) explains content streams and system selection controls.
- Apple's [NSWorkspace application opening](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:)) provides application launch/activation.
- Native cross-process embedding is not a supported capability assumed by this
  plan. The C0 spike must verify the proposed public-API behavior on supported
  OS versions. No Canvas performance or app-control experiment was run here.
