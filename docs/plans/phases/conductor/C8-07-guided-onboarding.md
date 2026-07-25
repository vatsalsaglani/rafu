# C8-07 — "New Ensemble…" (⌘⇧E): three doors, guided cold start

- **Status:** Ready. Branch: `conductor/c8-07-onboarding` (from `main`
  AFTER wave 2 fully merged — verify `ConductorCoordinatorLauncher` and
  `ConductorGraphModel` exist; either missing ⇒ STOP and report).
  Wave 3 — parallel with C8-04 and C8-05.
- **This kills the cold-start problem** — C8-ux problem #1, "the single
  biggest adoption risk in the whole feature."

## Goal

One sheet, three doors, guided preselected. A new user types a goal in
plain language, sets a visible budget grant, and gets a live coordinator
in a terminal tab — without ever authoring an agent file (D2: files
become an output of the first run). The template and expert doors reuse
what C6 already shipped. ⌘⇧E and a menu item open it; the guided door
launches through C8-03's `ConductorCoordinatorLauncher` and lands the
user on the graph canvas.

## Read first

`AGENTS.md` (interface rules, sheets); conductor `README.md`;
`C8-execution-plan.md` (decisions 3, 4); `C8-coordinator-ux.md` ("Three
doors, one default", "The consent model");
`Sources/RafuApp/Views/GitHubPublishSheet.swift` (the sheet structure to
copy: RafuSheetHeader, grouped Form, cancel/default keyboard shortcuts,
`RafuMetrics.sheetPadding`, fixed width);
`Sources/RafuApp/Views/ConductorRunsPanelView.swift`
(`ConductorNewRunSheet`, template confirmation flow,
`ConductorWorkflowLaunchModel` usage);
`Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift` +
`ConductorEnsembleGrant.swift` (C8-03's API);
`Sources/RafuApp/Settings/ConductorSettingsTab.swift` (adapter probe
pattern for the CLI picker); `swiftui-expert-skill`.

## Owned paths

- NEW `Sources/RafuApp/Views/EnsembleStartSheet.swift` (view + model)
- `Sources/RafuApp/Models/WorkspaceSession.swift` — sheet-flag seam ONLY
  (anchored below)
- `Sources/RafuApp/Views/WorkspaceWindowView.swift` — one `.sheet` line
  in `WorkspaceWindowPresentations`
- `Sources/RafuApp/App/RafuAppCommands.swift` — "New Ensemble…" ⌘⇧E
- `Sources/RafuApp/Views/CommandPaletteView.swift` — palette command
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift` — one
  "New Ensemble…" button beside "New Run…" in the header
- NEW tests `Tests/RafuAppTests/Conductor/EnsembleStartSheetTests.swift`
- Docs: `ensemble-manual-test-plan.md` NEW section **M**; NEW
  `docs/references/ensemble-onboarding.md`; this plan's status line.

**Forbidden:** engine files, `ConductorCore.swift`,
`ConductorRunDetailCanvas.swift`, `EditorCanvasView.swift`, everything
C8-04/C8-05 own this wave (Ensemble request service, skills, Settings,
`Package.swift`), adapters, `script/`.

## Design contract

### Entry points

- `WorkspaceSession` — immediately after the C8-06 graph seam (after
  `closeConductorGraph()`), add ONLY:
  `var ensembleStartSheetPresented: Bool = false` and
  `func presentEnsembleStartSheet()` (guards `descriptor != nil`).
- `RafuAppCommands.swift` Ensemble block, directly ABOVE "New Ensemble
  Run…": `Button("New Ensemble…") { workspaceSession?
  .presentEnsembleStartSheet() }.keyboardShortcut("e", modifiers:
  [.command, .shift])` — ⌘⇧E is verified free (in-use ⌘⇧ set: n f g l
  k p) and Command-modified shortcuts are safe app-wide per the block's
  own comment. `.disabled(workspaceSession?.descriptor == nil)`.
- Palette: `PaletteCommand(id: "conductor.new-ensemble", title: "New
  Ensemble…", keywords: ["ensemble","coordinator","goal","new"])`.
- Runs panel header: secondary-style "New Ensemble…" button beside
  "New Run…" (the sheet supersedes nothing — "New Run…" stays for
  direct single runs).
- `WorkspaceWindowPresentations` (in `WorkspaceWindowView.swift`):
  `.sheet(isPresented: $session.ensembleStartSheetPresented) {
  EnsembleStartSheet(session: session) }` beside the existing five.

### The sheet (`EnsembleStartSheet.swift`)

Structure copied from `GitHubPublishSheet`: `RafuSheetHeader(icon:
"circle.hexagongrid", title: "New Ensemble", subtitle: …)`, a
`RafuSegmentedPicker`-style door selector, a grouped `Form` per door,
footer Cancel (`.cancelAction`, secondary) + primary
(`.defaultAction`, prominent), width 480.

`@MainActor @Observable final class EnsembleStartModel` — no I/O in
init; adapter probes in `.task` (reuse the resolve path
`ConductorRoleLaunchService.resolve` / the Settings-tab probe pattern).

**Door 1 — "Describe a goal" (DEFAULT, preselected):**
- Coordinator CLI `Picker` over `ConductorAdapterRegistry.all`: a CLI is
  enabled only when probed available AND auth status is ready; disabled
  rows show the reason inline ("not installed", "not logged in — run
  `claude login` in a terminal") — glyph + text, never color alone.
  Optional model field (free text, prefilled from
  `ConductorDefaultModelStore` when set).
- Goal: multiline `TextEditor` (min 3 visible lines) with placeholder
  "What should the ensemble accomplish? Plain language."
- **Grant, always visible (the consent model — never buried):**
  Stepper "Max concurrent child runs" default 3 (1…3, capped by the
  window cap with a caption saying so); Stepper "Max total child runs"
  default 12; "Allowed CLIs" toggle row seeded to available+authed
  CLIs; wall-clock `Picker` (1 h / 4 h / 8 h / none → `deadline`);
  usage-ceiling field left OUT of v1 UI (grant supports it; record as
  follow-up) — honesty over knobs.
- Primary button "Start Coordinator": builds `ConductorEnsembleGrant`,
  calls `ConductorCoordinatorLauncher.start(provider:model:goal:grant:
  in:)`, dismisses, then `session.showConductorGraph()` — the user
  lands on the cockpit with the coordinator root node live and its
  terminal one click away. If the CLI has no initial-prompt argument
  form (per C8-03's probe notes), show the goal in a copyable field on
  a brief post-launch confirmation row INSIDE the sheet before
  dismissing ("Paste this into the coordinator's prompt") — never
  synthesize terminal input.
- Failure (probe raced, launch threw): inline error row, sheet stays
  open, nothing spawned.

**Door 2 — "From a template":** list the three
`ConductorBundledTemplateCatalog.templates` (name + description),
primary "Add to This Repository" → existing
`ConductorTemplateInstantiator` flow INCLUDING the existing
conflict-confirmation dialog (reuse the panel's `confirmationDialog`
logic — lift it into the sheet, don't duplicate policy); on success,
open the instantiated workflow file as a tab and switch the panel to
Workflows. This door teaches the file format by example.

**Door 3 — "Existing workflow" (expert):** embed the
`ConductorWorkflowLaunchModel` picker exactly as `ConductorNewRunSheet`'s
workflow mode uses it (scope-labeled workflows, role/model overrides,
launch-time validation); primary "Start Run" routes through
`session.conductorConcurrentRuns` via the same code path the panel
sheet uses today. Cap-aware guard: `session.canStartConductorWorkflowRun`
disables the button with the typed reason shown.

Accessibility: every door reachable by keyboard; the door picker is a
real segmented control; VoiceOver labels on disabled CLI rows include
the reason; Esc cancels; Reduce Motion — no transition animation
between doors.

## Tests

- `EnsembleStartSheetTests` (headless model tests): CLI gating matrix
  (absent / present-unauthed / ready ⇒ disabled reason vs enabled);
  grant construction (allowed set defaults to ready CLIs; deadline
  mapping; concurrent min(window cap)); goal required non-empty for
  door 1 primary; door 3 guard mirrors `canStartConductorWorkflowRun`;
  launch success path registers a coordinator session (FakeConductorAdapter
  + spy launcher) and flips `ensembleStartSheetPresented` false +
  `conductorGraphVisible` true; launch failure keeps the sheet with an
  error.
- Command availability: sheet flag guards on `descriptor == nil`.
- ⌘⇧E collision assertion: a test enumerating `RafuAppCommands`
  shortcuts is impractical — instead grep-based check documented in the
  report (state the verified in-use set).

## Gates

Standard four gates; HEADLESS ONLY — the sheet eyeball, keyboard-only
pass, VoiceOver spot-check, and second-window pass run on `main`
post-merge; list them explicitly in your report.

## Documentation deliverables

NEW `docs/references/ensemble-onboarding.md` (three-door contract, CLI
gating rules, grant defaults + where they surface, the paste-fallback
rule for prompt-less CLIs, follow-ups: usage-ceiling UI, editable
defaults in Settings). `ensemble-manual-test-plan.md` NEW section
**M — New Ensemble sheet** (M1 ⌘⇧E opens with guided preselected, M2
unauthed CLI disabled with reason, M3 grant visible + capped, M4 start
lands on graph with live coordinator, M5 template door instantiates +
opens file, M6 expert door cap-aware, M7 Esc/keyboard-only pass) + add
M4 to the ranked priority list. Intended index rows in the report.

## Handoff report

Delivered behavior; changed paths; test evidence; the exact GUI checks
for the coordinator; remaining risks/follow-ups; docs; branch; commit
messages; `git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/c8-07-onboarding. Preflight: run `git status --short
--branch` ONCE. On this branch + clean tree → proceed. Detached HEAD or
wrong branch + clean tree → checkout the branch if it exists, else
`git checkout -b conductor/c8-07-onboarding main`, then proceed and say
so. Dirty tree with edits you did not make → STOP. Then verify
prerequisites: ConductorCoordinatorLauncher
(Sources/RafuApp/Conductor/Ensemble/) and ConductorGraphModel
(Sources/RafuApp/Conductor/Run/) both exist. Either missing ⇒ STOP and
report — wave 2 has not merged.

GOAL: implement docs/plans/phases/conductor/C8-07-guided-onboarding.md —
the New Ensemble sheet with three doors (guided goal-first door
preselected: authed-CLI picker with inline disable reasons, plain-
language goal, an always-visible budget grant; template door reusing the
bundled-template instantiation + conflict confirmation; expert door
reusing the workflow launch model), opened via ⌘⇧E, the Rafu menu, the
palette, and a Runs-panel button, launching through
ConductorCoordinatorLauncher and landing the user on the graph canvas.
The plan file is your authoritative design contract, edit list, and
test list — read it FIRST, then AGENTS.md, the conductor README ground
rules, C8-coordinator-ux.md's "Three doors" and consent-model sections,
GitHubPublishSheet.swift (structure), ConductorRunsPanelView.swift
(existing sheet + template flow), and C8-03's coordinator/grant API.
Use swiftui-expert-skill.

HARD CONSTRAINTS: the guided door is default and complete without prior
knowledge of agent files; the grant is visible in the sheet, never
buried; CLIs the user has not authed are disabled with a stated reason
(glyph + text, never color alone); never synthesize terminal input —
prompt-less CLIs get the copyable-goal fallback; reuse the existing
template-conflict and workflow-launch code paths, never duplicate their
policy; @State stays private; no I/O in model init; user-visible
strings say Ensemble. DO NOT touch engine files, ConductorCore.swift,
EditorCanvasView.swift, ConductorRunDetailCanvas.swift, Settings,
Package.swift, or the Ensemble request service — C8-04/C8-05 own those
this wave. HEADLESS ONLY — list the required GUI checks for the
coordinator instead of launching the app.

DEFINITION OF DONE:
1. ⌘⇧E / menu / palette / panel button all open the sheet (flag-guarded
   on an open workspace); Esc cancels.
2. Door 1 end-to-end headless: gating matrix tested; Start builds the
   grant, launches via ConductorCoordinatorLauncher (spy-verified),
   closes the sheet, and shows the graph canvas; failure keeps the
   sheet with an inline error and spawns nothing.
3. Doors 2 and 3 reuse the existing instantiation and launch paths,
   cap-aware, tested at the model level.
4. swift build 0 warnings; swift test AND swift test --no-parallel
   green; format --fix + --lint clean.
5. ensemble-onboarding.md written; manual-test-plan section M added
   with M4 in the priority list; intended index rows in the report.
6. Work committed locally in verified stages; never push/merge/rebase/
   checkout main. Shared-file needs are a HANDOFF with a proposed diff.

FINAL REPORT (mandatory): delivered behavior; changed paths; test
evidence; the exact GUI checks the coordinator must run on main;
remaining risks and recorded follow-ups; docs written; branch name;
every commit message; last commit id from `git rev-parse HEAD`.
```
