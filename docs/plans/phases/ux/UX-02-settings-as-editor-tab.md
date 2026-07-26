# UX-02 — Settings as an editor tab

- **Status:** Implemented and verified on `ux/02-settings-tab` (2026-07-26).
  Branched from `main` after UX-00; Wave 2 — parallel with UX-01.

## Goal

Host Rafu's settings in the editor canvas instead of a separate window, and
add a settings affordance at the **bottom-right of the editor**. Settings
becomes something you keep open beside your code, not a window you summon
and dismiss.

## The one thing to get right

macOS has a strong convention: **⌘, opens Settings**, and users expect it to
work from anywhere. Moving settings into a tab must not break that
expectation or make settings unreachable when no workspace is open.

So this is not a straight replacement. Decide and record:

- **⌘, and the app-menu item must keep working.** With a workspace open they
  route to the canvas tab. With **no window open**, a canvas cannot host
  anything — so either keep the `Settings` scene as the fallback for that
  case, or open a workspace-less window. Pick one, justify it, and make sure
  ⌘, never silently does nothing.
- The `Settings` scene may remain registered as that fallback. Deleting it
  outright is the riskier option; if you do delete it, prove ⌘, still works
  from a state with no windows.

Getting this wrong is worse than the modal was, because an unreachable
settings screen is unrecoverable without editing defaults by hand.

## Read first

`AGENTS.md` (macOS interface rules: standard scenes and commands before
custom chrome — this plan deliberately narrows that, so justify it in the
note); `docs/references/editor-canvas-routing.md` (UX-00's route);
`Sources/RafuApp/Settings/RafuSettingsView.swift` (the seven-tab `TabView`,
fixed 760×620 frame — that frame is a window sizing decision that will not
survive into a canvas);
`Sources/RafuApp/App/RafuApp.swift` (the `Settings` scene);
`Sources/RafuApp/Views/WorkspaceStatusBar.swift` (the bottom bar — the most
likely home for the button);
`Sources/RafuApp/Views/ConductorRunDetailCanvas.swift` (editor-hosted canvas
pattern); `swiftui-expert-skill`, Build macOS Apps `swiftui-patterns`.

## Owned paths

- `Sources/RafuApp/Settings/**` (all seven panes + `RafuSettingsView`)
- `Sources/RafuApp/App/RafuApp.swift` (the `Settings` scene decision)
- `Sources/RafuApp/App/RafuAppCommands.swift` — the settings command only
  (UX-01 edits other regions of this file in parallel; keep your hunk tight)
- `Sources/RafuApp/Editor/EditorCanvasRoute.swift` — **one case only**
- `Sources/RafuApp/Views/EditorCanvasView.swift` — **one switch arm only**
- `Sources/RafuApp/Models/WorkspaceSession.swift` — settings canvas seam,
  anchored beside the existing canvas methods
- `Sources/RafuApp/Views/WorkspaceStatusBar.swift` — the settings button
- NEW `Tests/RafuAppTests/SettingsCanvasTests.swift`
- NEW `docs/references/settings-surface.md`; this plan's status line.

**Forbidden:** everything UX-01 owns (`EnsembleStartSheet`,
`ConductorRunsPanelView`, `WorkspaceWindowView`, the palette),
everything UX-03 owns (terminals panel, `TerminalsPanelModel`,
`ConductorCLIIcons`, `FileIconProvider`), `RafuControlStyles.swift`
(UX-00 — consume), and any settings *behaviour*: this plan re-hosts the
panes, it does not change what they do.

## Design contract

### 1. The route

Add `case settings` to `EditorCanvasRoute` plus the `WorkspaceSession` seam,
beside the existing canvas methods.

**Before anything else: your activator must clear the other canvas modes,
and theirs must clear yours.** Exclusivity lives in the mutators, not the
resolver — that is why the existing modes' relative precedence is
unreachable. A mode that sets its own flag without clearing the others makes
the ordering suddenly load-bearing, and the bug is "the wrong screen appears"
with no error and no failing test. See `editor-canvas-routing.md`,
"Exclusivity lives in the mutators", and extend its table.

Settings is a **peer** of run detail and graph: opening it replaces them, and
opening them replaces it — the same mutual exclusion those two already have.

### 2. Re-host the panes unchanged

`RafuSettingsView` is a `TabView` of seven panes sized `760×620`. In a canvas:

- **Drop the fixed frame.** A hardcoded window size inside an editor canvas
  produces either a cramped box or dead space. Let the canvas own width and
  constrain content to a readable measure, centred — the same treatment
  UX-01 applies to the Ensemble form.
- Keep the seven panes and their models **behaviourally identical**. Their
  `.task`-driven loading, probe refreshes, and `no I/O at init` discipline
  all stay. This is a container change.
- The `TabView` may become a sidebar/segmented layout if it reads better at
  canvas width — that is a presentation choice you may make, but say so and
  keep every pane reachable by keyboard.

### 3. The bottom-right button

Add a settings affordance to the right end of `WorkspaceStatusBar`. Icon-only
is acceptable here **with** a `.help` tooltip and an accessibility label,
because ⌘, and the app menu remain the primary paths — an icon is a shortcut
to an already-reachable action, not the sole carrier of it.

Match the status bar's existing sizing and muted treatment. It sits beside
existing indicators, so it must not shout: this is a utility affordance, not
a call to action.

### 4. Restoration

Settings is **not** a restorable tab. On relaunch the user should get their
code back, not a settings screen. Follow the terminal precedent
(ADR 0014-style ephemerality) and make sure the canvas state does not
persist into `RestorableWorkspace`.

## Tests

- Route test: `settings` resolves, is mutually exclusive with `runDetail`
  and `graph`, and a selected document beats it.
- ⌘, reaches settings **with** a workspace open and **without** one — this
  is the load-bearing test of the plan.
- The settings canvas is not restored after a simulated relaunch.
- Existing settings pane tests (`ConductorSettingsTests`,
  `EnsembleSettingsTests`) pass unchanged — they assert model behaviour,
  which this plan must not disturb.
- Second-window independence.

## Gates

Standard build/parallel-per-stage/serial-once/format; `rm -rf .build` last.

**Run `./script/build_and_run.sh --verify`.** Check specifically: ⌘, with a
workspace, ⌘, with every window closed, the button's tooltip, every pane
reachable by keyboard, and that content is neither cramped nor stretched.
Never `pkill`/`pgrep` a bare `Rafu`.

## Documentation deliverables

NEW `docs/references/settings-surface.md`: the canvas route, the ⌘,
fallback decision **and why**, the dropped fixed frame, non-restorability,
and the narrowing of AGENTS.md's "standard scenes first" rule with its
justification. That last part matters — a future agent reading AGENTS.md
will otherwise see this as a violation rather than a recorded decision.

Note in the same file whether `AGENTS.md`'s macOS interface bullet needs
amending; propose the wording in your report rather than editing it, since
UX-01 and UX-03 may be touching shared docs in the same wave.

## Handoff report

Delivered; changed paths; **the ⌘,-with-no-window decision and its
evidence**; whether the `Settings` scene survived and why; the layout choice
for seven panes at canvas width; test evidence; the Lightning GUI pass;
proposed AGENTS.md wording if any; branch; commit messages;
`git rev-parse HEAD`.

---

## Goal-mode agent prompt

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: ux/02-settings-tab. Preflight: run `git status --short --branch`
ONCE. On this branch + clean tree → proceed. Detached HEAD or wrong branch
+ clean tree → checkout it if it exists, else `git checkout -b
ux/02-settings-tab main`, then proceed and say so. Dirty tree with edits
you did not make → STOP. Then verify Sources/RafuApp/Editor/
EditorCanvasRoute.swift exists — missing ⇒ STOP, UX-00 has not merged.

GOAL: implement docs/plans/phases/ux/UX-02-settings-as-editor-tab.md —
host settings in the editor canvas as a new route, and add a settings
button at the bottom-right of the editor (status bar). Read that plan
FIRST, then AGENTS.md, docs/references/editor-canvas-routing.md, and the
files its "Read first" names. Use swiftui-expert-skill and swiftui-patterns.

THE LOAD-BEARING RISK: macOS users expect ⌘, to open Settings from
anywhere. A canvas cannot host anything when no window is open. So ⌘, must
keep working in BOTH states — decide whether to keep the Settings scene as
the no-window fallback or open a workspace-less window, justify it, and
TEST both. An unreachable settings screen is unrecoverable without editing
defaults by hand, which is strictly worse than the window you replaced.

This is a re-host: the seven panes keep their behaviour, their .task-driven
loading, and their no-I/O-at-init discipline. Their existing tests must
pass unchanged. Do drop RafuSettingsView's fixed 760x620 frame — a window
sizing decision inside a canvas produces a cramped box or dead space —
and constrain content to a readable centred measure instead. Settings is
NOT restorable: on relaunch the user gets their code back, not a settings
screen.

HARD CONSTRAINTS: add exactly one case to EditorCanvasRoute and one switch
arm; anchor your WorkspaceSession seam beside the existing canvas methods,
because UX-01 adds two routes to the same two files in parallel; keep your
RafuAppCommands hunk to the settings command only (UX-01 edits other
regions); the status-bar button may be icon-only ONLY with a .help tooltip
and an accessibility label, since ⌘, and the menu remain primary. DO NOT
touch EnsembleStartSheet, ConductorRunsPanelView, WorkspaceWindowView, the
command palette, the terminals panel, ConductorCLIIcons, or
RafuControlStyles.

Local builds are Rafu Lightning. You MUST run ./script/build_and_run.sh
--verify, and specifically test ⌘, with a workspace open AND with every
window closed. Never pkill or pgrep a bare "Rafu": that is the user's
editor.

DEFINITION OF DONE:
1. Settings renders in the editor canvas, mutually exclusive with run
   detail and graph, non-restorable.
2. ⌘, works with a workspace open and with no window open — both tested.
3. A status-bar settings button with tooltip and accessibility label.
4. Existing settings pane tests pass unchanged; content neither cramped
   nor stretched at canvas width.
5. build 0 warnings; parallel per stage; serial once; format clean.
6. settings-surface.md written, recording the ⌘, decision and the
   narrowing of AGENTS.md's "standard scenes first" rule; propose any
   AGENTS.md wording in your report rather than editing it.
7. Committed in verified stages; `rm -rf .build` last. Never
   push/merge/rebase/checkout main.

FINAL REPORT: delivered; changed paths; the ⌘,-with-no-window decision and
evidence; whether the Settings scene survived and why; the seven-pane
layout choice; test evidence; the Lightning GUI pass; proposed AGENTS.md
wording; branch; every commit message; last commit id.
```
