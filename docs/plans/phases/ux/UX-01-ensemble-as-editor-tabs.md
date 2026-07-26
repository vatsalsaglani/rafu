# UX-01 — Ensemble surfaces become editor tabs, not modals

- **Status:** Ready. Branch: `ux/01-ensemble-tabs` (from `main` AFTER UX-00
  merges — verify `Sources/RafuApp/Editor/EditorCanvasRoute.swift` exists;
  missing ⇒ STOP and report). Wave 2 — parallel with UX-02.

## Goal

Move **New Ensemble** and **New Ensemble Run** out of modal sheets and into
the editor canvas, and fix the Runs panel header, whose two text buttons
truncate to "New Ensem…" in a 40 pt-wide panel.

The standing preference behind this: **a surface that can be an editor tab
should be one.** A modal steals the window, cannot be left open while you
read a file, and cannot be reached back into. Both of these are
configuration surfaces the user wants to consult *while* looking at their
repository — exactly the case a tab serves and a sheet defeats.

## Read first

`AGENTS.md` (interface rules; no gesture-only or icon-only *meaning*);
`docs/references/editor-canvas-routing.md` (UX-00's route — you add cases to
it); `docs/references/ensemble-onboarding.md` (C8-07's three-door contract —
the behaviour you are re-hosting, not redesigning);
`Sources/RafuApp/Views/EnsembleStartSheet.swift` (835 lines — the three
doors, the grant form, the copyable-goal confirmation);
`Sources/RafuApp/Views/ConductorRunsPanelView.swift`
(`ConductorNewRunSheet` at ~line 466, the header at ~line 111-140, the
segmented picker UX-00 already themed);
`Sources/RafuApp/Views/ConductorRunDetailCanvas.swift` (the existing
editor-hosted canvas pattern to copy); `swiftui-expert-skill`.

## Owned paths

- `Sources/RafuApp/Views/EnsembleStartSheet.swift` → becomes a canvas view
  (rename the type; keep the model and its tests intact)
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift` (the New Run sheet,
  the header buttons)
- `Sources/RafuApp/Editor/EditorCanvasRoute.swift` — **add two cases only**
- `Sources/RafuApp/Views/EditorCanvasView.swift` — **two switch arms only**
- `Sources/RafuApp/Models/WorkspaceSession.swift` — Ensemble canvas seam,
  anchored beside the existing `showConductorRunDetail` /
  `showConductorGraph` methods; nothing elsewhere in the file
- `Sources/RafuApp/Views/WorkspaceWindowView.swift` — **removing** the
  Ensemble `.sheet` lines only
- `Sources/RafuApp/App/RafuAppCommands.swift`,
  `Views/CommandPaletteView.swift` — repoint the existing entries at the
  canvas instead of the sheet flag
- `Tests/RafuAppTests/Conductor/EnsembleStartSheetTests.swift` (rename/extend)
- `docs/references/ensemble-onboarding.md`;
  `docs/plans/phases/conductor/ensemble-manual-test-plan.md` §M (update the
  entry-point rows); this plan's status line.

**Forbidden:** `Settings/**` and the settings route (UX-02 owns them),
`WorkspaceTerminalsPanelView` / `TerminalsPanelModel` / `ConductorCLIIcons`
(UX-03), `RafuControlStyles.swift` (UX-00 — consume), the Ensemble engine and
request service, `ConductorGraphCanvas.swift`.

## Design contract

### 1. Two new routes

Add `case ensembleStart` and `case ensembleNewRun` to `EditorCanvasRoute`,
and the matching `WorkspaceSession` state beside the existing canvas seams.

**Before anything else: your activators must clear the other canvas modes,
and theirs must clear yours.** Exclusivity lives in the mutators, not the
resolver — `showConductorRunDetail` clears `conductorGraphVisible` and vice
versa, which is why their relative precedence is unreachable. A mode that
sets its own flag without clearing the others makes the ordering suddenly
load-bearing, and the bug is "the wrong screen appears" with no error and no
failing test. See `editor-canvas-routing.md`, "Exclusivity lives in the
mutators", and extend its table.
**Where they sit in the precedence order is a real decision:** put them
above `editor` and below `blame`/`standaloneDiff`, matching how
`runDetail`/`graph` already behave, and add the route tests that pin it.
They are peers of the run-detail and graph canvases — opening one replaces
the other, exactly as those two already do to each other.

### 2. Re-host, do not redesign

C8-07's three doors, the always-visible budget grant, the CLI gating with
inline reasons, the copyable-goal confirmation, and the template/expert
reuse of C6's paths are **all correct and must survive verbatim in
behaviour**. Its model and tests already exist; keep them and change the
container. Resist the temptation to improve the flow while moving it — a
re-host with a behaviour change is impossible to review.

Two things genuinely change because the container changed:

- **Cancel/Esc semantics.** A sheet dismisses; a tab closes. Esc should
  close the tab, and the tab must be closeable like any other. There is no
  `.cancelAction` in a canvas, so wire the equivalent explicitly.
- **Width.** The sheet was a fixed 480 pt. A canvas is the full editor
  width, and a 2000 pt-wide form is worse than a modal. Constrain the
  content to a readable measure (~520-640 pt) centred in the canvas, the
  way a document view would be. Do not let the form stretch.

### 3. The panel header

Two text buttons ("Graph", "New Ensem…") do not fit a 40 pt panel and
truncate. Make them **icon-only** — but per AGENTS.md, an icon may not be
the only carrier of meaning, so each needs a `.help` tooltip **and** an
accessibility label, and both actions must remain reachable from the Rafu
menu and the command palette (they already are — verify, do not assume).
That combination is what makes icon-only legitimate here rather than a
violation.

Use `RafuIconButtonStyle`, matching the activity strip's existing sizing.

### 4. Remove the sheets

Delete the Ensemble `.sheet` presentations from
`WorkspaceWindowPresentations` and the flags that drove them. Repoint
⌘⇧E, the menu item, the palette command, and the panel button at the canvas
seam. **Leave the template-conflict `confirmationDialog` alone** — that is a
genuine destructive-action confirmation, which is exactly what a modal is
for; the no-popups preference is about surfaces, not about safety prompts.

## Tests

- Route tests for both new cases, including precedence against
  `runDetail`/`graph`/`editor` and mutual replacement.
- The existing `EnsembleStartSheetTests` behaviours all still pass against
  the canvas host (rename the file; keep the assertions).
- All four entry points (⌘⇧E, menu, palette, panel button) reach the canvas
  and none presents a sheet.
- Esc/close returns to the previous canvas occupant, matching
  `closeConductorRunDetail`'s fallback behaviour.
- Second-window independence: opening the canvas in one window does not
  affect the other.

## Gates

Standard build/parallel-per-stage/serial-once/format; `rm -rf .build` last.

**Run `./script/build_and_run.sh --verify`** and do a real pass: the form is
readable and not stretched, Esc closes, the header icons are legible with
working tooltips, and manual-test §M still passes with "tab" substituted for
"sheet". Never `pkill`/`pgrep` a bare `Rafu`.

## Documentation deliverables

Update `docs/references/ensemble-onboarding.md` for the canvas host (entry
points, Esc/close, the width constraint and why). Update
`ensemble-manual-test-plan.md` §M's entry-point rows. Record in the
onboarding note the general rule this establishes: **configuration surfaces
are editor tabs; modals are reserved for destructive confirmations.**

## Handoff report

Delivered; changed paths; the precedence decision for the two new routes;
proof C8-07's behaviours survived (which tests carried over unchanged); the
Lightning GUI pass; branch; commit messages; `git rev-parse HEAD`.

---

## Goal-mode agent prompt

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: ux/01-ensemble-tabs. Preflight: run `git status --short --branch`
ONCE. On this branch + clean tree → proceed. Detached HEAD or wrong branch
+ clean tree → checkout it if it exists, else `git checkout -b
ux/01-ensemble-tabs main`, then proceed and say so. Dirty tree with edits
you did not make → STOP. Then verify Sources/RafuApp/Editor/
EditorCanvasRoute.swift exists — missing ⇒ STOP, UX-00 has not merged.

GOAL: implement docs/plans/phases/ux/UX-01-ensemble-as-editor-tabs.md —
move New Ensemble and New Ensemble Run out of modal sheets into the editor
canvas as two new routes, and make the Runs panel header buttons icon-only
so they stop truncating. Read that plan FIRST, then AGENTS.md,
docs/references/editor-canvas-routing.md, and
docs/references/ensemble-onboarding.md. Use swiftui-expert-skill.

THIS IS A RE-HOST, NOT A REDESIGN. C8-07's three doors, always-visible
budget grant, CLI gating with inline reasons, copyable-goal confirmation,
and template/expert reuse are all correct: their behaviour must survive
verbatim, and its existing tests should carry over with assertions
unchanged. Do not improve the flow while moving it — a re-host with a
behaviour change cannot be reviewed.

Two things DO change because the container changed, and both need
deliberate work: Esc/close semantics (a tab closes, there is no
.cancelAction), and width — the canvas is full-editor-width, so constrain
the form to a readable measure (~520-640pt) centred, or it becomes worse
than the modal was.

HARD CONSTRAINTS: icon-only header buttons are only legitimate WITH a
.help tooltip, an accessibility label, and the same actions reachable from
the menu and palette — verify that, do not assume it; leave the
template-conflict confirmationDialog alone, because the no-popups
preference is about surfaces, not safety prompts; add exactly two cases to
EditorCanvasRoute and two switch arms, and put your WorkspaceSession seam
beside the existing canvas methods — UX-02 adds a settings route to the
same two files in parallel. DO NOT touch Settings/**,
WorkspaceTerminalsPanelView, TerminalsPanelModel, ConductorCLIIcons,
RafuControlStyles, the Ensemble engine, or ConductorGraphCanvas.

Local builds are Rafu Lightning. You MUST run ./script/build_and_run.sh
--verify — the point of this work is how it feels. Never pkill or pgrep a
bare "Rafu": that is the user's editor.

DEFINITION OF DONE:
1. No Ensemble modal remains; all four entry points reach the canvas.
2. C8-07's behaviours are intact, evidenced by carried-over tests.
3. Esc/close returns to the previous canvas occupant; second-window
   independence tested.
4. Header buttons are icon-only, legible, with tooltips, labels, and
   menu/palette equivalents.
5. The form is constrained to a readable width, verified visually.
6. build 0 warnings; parallel per stage; serial once; format clean.
7. ensemble-onboarding.md and manual-test §M updated.
8. Committed in verified stages; `rm -rf .build` last. Never
   push/merge/rebase/checkout main.

FINAL REPORT: delivered; changed paths; the route precedence decision;
which tests carried over unchanged; the Lightning GUI pass; branch; every
commit message; last commit id.
```
