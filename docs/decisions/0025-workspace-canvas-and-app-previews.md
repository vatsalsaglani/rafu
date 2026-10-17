# ADR 0025: Workspace Canvas and app previews

- Status: Accepted by the user's implementation direction, 2026-10-17.
- Scope: Optional local-workspace Canvas alongside file and Terminal Group tabs.
- Execution: One agent, sequential C0–C5 stages, local commits only.

## Decision

A Canvas is a named, typed editor resource owned by one workspace window. It
contains bounded file and image references, native notes, Terminal Group
references, explicit local web previews, native app references and optional
selected-window previews, and labeled relationships. Relationships execute no
commands or workflows. Existing Settings and Ensemble tabs keep their current
window-only behavior. Canvas does not replace the editor or the Ensemble graph.

This narrowly extends ADR 0002's editor-hosted surfaces. It permits bounded
WebKit use for a user-connected loopback web application only. ADR 0019 and
0020 keep document/media/Markdown/Mermaid rendering native. No extension host,
embedded coding agent, task runner, or inference credential authority is added.

Native app cards use public NSWorkspace activation and ScreenCaptureKit's
single-window system picker. Captured frames are temporary, local previews.
Keyboard and pointer input belong to the actual app after Open App. No foreign
NSView embedding, private window APIs, synthetic input, Accessibility grant,
recording, audio capture, OCR, or agent transmission is part of this decision.
A closed or unavailable source returns to a useful app-reference card.

Terminal Groups retain one runtime owner, controller, and PTY. A presentation
lease permits one visible host at a time across its regular tab and Canvas.
Transfers invalidate old focus requests. Board zoom never repeatedly resizes
PTYs. Existing explicit start/close rules and ADR 0024's independent capacities
remain authoritative; a Canvas does not add another process allowance.

Live notes remain in native text storage. Observation carries small metadata.
A bounded text snapshot is taken for atomic save/recovery. Workspace-keyed
Application Support holds Canvas files, with expected-version checks and
cross-window conflict handling. Source files are never written by card removal.
Saved boards restore inertly: no process, browser load, app launch, capture, or
permission grant. Persist no terminal output, prompt, environment, command,
cookie, token, PID, foreign window ID, or captured frame.

Board/content focus is explicit. Focus stays inside the Canvas tab; an always
visible Leave Content/Back to Canvas route protects terminal and web input.
Canvas List and visible/menu/keyboard actions provide non-spatial access.
Undo restores references and geometry, never live resource capability.

Initial ceilings: 10 boards per workspace, 100 cards and 200 relationships per
board, 64 KiB per note and 2 MiB per encoded board, two web controllers and two
capture streams per window. Capture starts at bounded resolution and 10 fps.
Hidden captures stop; hidden web controllers unload. Existing terminals continue
to drain output when parked. These are ceilings, not performance claims.

## Execution and evidence

The baseline repair and planning commit is `0c4db05`. The user's latest direction
supersedes the proposed parallel worktree plan: use one checkout and one agent,
keep C0–C5 dependency order, and make local commits. Do not create an implementation
fan-out or push application code. Consult Astra at Medium only if needed.

C0 probes verify the SDK boundaries and native view transfer before integration.
Interactive picker permission/source-loss cases are checked through the finished
visible controls during C4/C5; no automatic permission request is added merely
to run a probe. Record untested OS versions or unavailable permissions explicitly.
Measurements and final checks are recorded in the active phase and Canvas reference.

## Consequences

WebKit and ScreenCaptureKit are replaceable adapters with explicit resource
lifetime. The Canvas store owns no terminal process or full source-file text.
Existing dirty documents and their undo stacks must survive all Canvas switches.
Missing or corrupt saved Canvas data cannot discard the rest of the workspace.
Multiwindow writes must detect conflicts rather than silently overwrite notes.
