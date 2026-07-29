# WP-60 — Goal-first Ensemble composer and run canvases

## Status and execution slot

- **Status:** Planned.
- **Wave:** 1; parallel.
- **Suggested branch:** `codex/presentation-ensemble`.
- **Recommended model:** `gpt-5.6-terra` with xhigh reasoning.
- **Required base:** exact `<FOUNDATION_SHA>`.
- **Merge round:** after WP-50.

## Goal

Make New Ensemble lead with the user's goal, represent each CLI/model
relationship once, and keep the primary action visible. Apply the shared
attached-tab grammar to the owned Ensemble canvases while preserving model
resolution, grants, delegated auth, explicit launch, file handoffs, and all
internal `Conductor*` naming.

WP-40 owns the Runs panel and New Run canvas. This lane owns the New Ensemble
composer, graph canvas, and run-detail canvas and must not edit the Runs panel.

## Required reading and skills

Read:

- `AGENTS.md`
- [`README.md`](README.md)
- [`WP-00-foundation.md`](WP-00-foundation.md)
- [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md)
- parent plan sections B/owned canvas tabs, G, P5, verification, and risks
- ADR 0018 and ADR 0022
- `docs/plans/phases/conductor/README.md`
- `docs/plans/phases/conductor/C8-coordinator-ux.md`
- `docs/plans/phases/conductor/ensemble-manual-test-plan.md`
- `docs/references/ensemble-onboarding.md`
- `docs/references/settings-surface.md` for hierarchy vocabulary only
- `docs/references/skill-routing.md`

Use `swiftui-expert-skill` with latest APIs, view structure, layout, lists,
focus, accessibility, scroll, and macOS views. Use Build macOS Apps
`swiftui-patterns`. Do not use the presence of orchestration code as authority
to change processes, adapters, grants, or trust boundaries.

## Exclusive ownership

Source:

- `Sources/RafuApp/Views/EnsembleStartCanvas.swift`
- rename `Sources/RafuApp/Views/EnsembleCLIIconGrid.swift` to
  `Sources/RafuApp/Views/EnsembleCLISelectionList.swift`
- `Sources/RafuApp/Views/EnsembleModelField.swift`
- `Sources/RafuApp/Views/EnsembleGoalPane.swift`
- `Sources/RafuApp/Views/ConductorGraphCanvas.swift`
- `Sources/RafuApp/Views/ConductorRunDetailCanvas.swift`

Tests:

- `Tests/RafuAppTests/Conductor/EnsembleStartCanvasTests.swift`
- `Tests/RafuAppTests/Conductor/GraphCanvasRoutingTests.swift`
- new `Tests/RafuAppTests/Conductor/EnsemblePresentationTests.swift`

Documentation:

- this plan's implementation record
- one uniquely named reference note only for a newly verified reusable
  selection/accessibility/canvas nuance

Do not edit `ConductorRunsPanelView.swift`,
`ConductorRunsPanelPresentationTests.swift`, `WorkspaceSession.swift`, any
Conductor domain/adapter/store/launcher file, WP-00 support files, `Package.*`,
shared indexes, or another lane's files.

WP-00 must already have moved Runs/entry-point source scans out of
`EnsembleStartCanvasTests.swift`. Stop if that ownership split is missing.

## Implementation

### N1. Use attached tabs on owned canvases

Apply WP-00's attached canvas tab to:

- New Ensemble;
- Ensemble graph;
- run detail.

Remove local underline-only variants while preserving close, route, title,
status, keyboard, and canvas lifecycle. WP-40 independently applies the same
primitive to New Run.

### N2. Put Name and Goal first

The source and visual order is:

1. Name and goal.
2. Lead/coordinator CLI and its model.
3. Budget and deadline.
4. Allowed CLIs and their models.
5. Start action.

Keep the header below 100 pt and place Name with **New Ensemble**. Retain the
three entry doors and suggested-name behavior.

In the guided door:

- put the goal pane first in source and visual order;
- give it flexible width with 420 pt minimum;
- use a 4 pt `appBackground` gutter;
- put a 300 pt trailing configuration rail second;
- use 5 pt bounded surfaces;
- do not use accessibility sort priority to disguise contradictory source
  order.

At 1,440 × 900 with Runs open, Name, Goal, lead/model, and Start must all be
visible.

### N3. Replace repeated icon-grid plus picker stacks

Rename `EnsembleCLIIconGrid` to `EnsembleCLISelectionList` and add
`EnsembleCLISelectionRow`.

Each row represents one CLI/model relationship:

- first logical line: provider icon, name, readiness, radio/checkbox;
- second logical line: resolved model summary or inline model popup;
- coordinator/lead uses single-selection/radio semantics;
- Allowed CLIs use multi-selection/checkbox semantics;
- unavailable CLI remains visible with explicit **Unavailable** plus its reason;
- compact widths may wrap the second line but may not create a separate
  repeated picker stack.

Remove the card grid followed by duplicated labels/`EnsembleModelField`s.
Each CLI/model pair appears exactly once.

### N4. Preserve model truth

Keep `EnsembleModelField` behavior:

- CLI default is not presented as an explicit selected model;
- inherited/default resolution remains explained;
- curated, discovered, and custom models remain selectable;
- **Custom…** free text remains available;
- no discovery/probe or I/O in view initialization;
- unavailable/readiness truth remains explicit.

Do not change `ConductorModelResolution`, stores, caches, adapters, or auth.

### N5. Clarify common versus advanced configuration

- Keep lead CLI/model visible.
- Put Budget Grant and detailed Allowed CLI controls into compact sections or
  disclosures without hiding the common path.
- Give `EnsembleGoalPane` a clear local frame and focused `focusRing`.
- Preserve its one-pane edit/render behavior and no Markdown parsing on the
  typing path.
- Keep the footer 52 pt and always visible.
- Use secondary **Close** and exactly one filled **Start Coordinator**.
- If Start is disabled, explain the missing requirement inline.

Keep all grant enforcement, window caps, deadlines, paste fallback, explicit
launch, error retention, run routing, and terminal creation unchanged.

### N6. Naming and accessibility

- No new user-visible “Conductor” string.
- Do not rename any internal `Conductor*` symbol or directory.
- Lead and Allowed groups have distinct accessibility roles/labels.
- Provider name, readiness, unavailability reason, and resolved/inherited model
  are announced without color.
- Keyboard/VoiceOver order follows the source order above.
- Larger text keeps two-line relationships readable; advanced content may
  scroll, while footer and common path remain coherent.

### N7. Tests

Deliberately replace stale source contracts for:

- 3/12-to-9/12 split;
- two `EnsembleCLIIconGrid` instances;
- separate repeated model picker stack.

Pin:

- exact source order and 420/300/4 pt composition;
- header under 100 and footer 52;
- one representation per CLI/model;
- single versus multi selection semantics;
- explicit unavailable reasons;
- attached tabs on all three owned canvases;
- disabled Start explanation;
- no new user-facing “Conductor” string.

Keep behavior assertions for model resolution, inherited/custom selection,
grant caps/deadlines, explicit launch, failure retention, goal bytes, and
window routing.

## Acceptance and manual evidence

Focused checks:

```bash
./script/test.sh --filter \
  'EnsembleStartCanvas|GraphCanvasRouting|ConductorModelResolution|EnsembleGrant|EnsembleCoordinatorLaunch|EnsemblePresentation'
```

At 1,440 × 900 with Runs open, capture:

- ready and unavailable providers;
- inherited and custom models;
- empty and filled goal;
- disabled and enabled Start;
- attached New Ensemble, graph, and run-detail tabs.

Verify one CLI/model representation, goal-first keyboard order, single/multi
VoiceOver semantics, Escape/Close, and Start as the only filled action. Test
provider rows and selection controls in rest/hover/pressed/selected/disabled
and unavailable states; shape, role, text, and announced value must communicate
state without hue. Test default and largest supported accessibility text sizes.
Capture Indigo, Khadi, converged surfaces, and Increase Contrast.

## Verification and handoff

Complete all changes before:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Use the single Rafu Lightning GUI lease or report exact deferred states. Commit
only owned paths, do not push, and remove `.build` after the green commit.

### WP-60 manual and accessibility matrix

Run this matrix in one Rafu Lightning window at 1,440 × 900 with Runs open;
use the same workspace for every row so the tab lifecycle and window-scoped
selection remain meaningful. Record **Pass**, **Fail**, or **N/A** with the
observed state. A lane without the single GUI lease records the exact rows
deferred to the coordinator merge round rather than implying a manual pass.

| Surface | States and evidence |
|---|---|
| Goal-first common path | Name, Goal, selected lead and its model, Budget grant, and Start Coordinator are visible together; the goal is first after Name in Tab and VoiceOver order. |
| Provider truth | Show one ready and one unavailable CLI. The unavailable row visibly says **Unavailable** and its reason; ready, hover, pressed, selected, disabled, and unavailable states remain distinguishable by text, shape, and role without hue. |
| Selection and models | Confirm lead rows announce a single-selection radio role and Allowed CLIs announce multi-selection checkbox roles. Check inherited/default, discovered where available, and **Custom…** model selection; each CLI/model relationship appears only in its one row. |
| Start state | Check empty goal, no allowed CLI, and a valid goal/lead/grant. Each disabled Start Coordinator state has an inline reason; enabled Start is the only filled footer action and Close remains secondary. |
| Attached canvases | Open New Ensemble, Ensemble Graph, and run detail. Each selected tab has the shared attached cap with no bottom seam, a visible close control, and Escape/Close retains its current route and fallback behavior. |
| Theme and contrast | Repeat the common path in Indigo, Khadi, and the converged-surface fixture with Increase Contrast. Verify the 4 pt gutter, 5 pt local surfaces, focus ring, and status/selection remain legible without hard-coded color. |
| Larger text and keyboard | At default and the largest supported text size, provider rows retain both logical lines, advanced rail content scrolls, and the footer remains visible. Complete the guided door using Tab, Space, Return, and Escape only. |
| VoiceOver and motion | With VoiceOver, confirm provider name, readiness, unavailable reason, model truth, and lead/allowed group labels; verify controls are individually reachable. With Reduce Motion and Reduce Transparency, no decorative transition appears and the compact surfaces remain coherent. |

## Implementation record

- Replaced the two icon grids and detached allowed-model stack with the
  compact `EnsembleCLISelectionList`/`EnsembleCLISelectionRow` relationship
  rows. Lead selection is single-select and Allowed selection is multi-select;
  readiness, explicit unavailability reason, model resolution, inherited
  defaults, and **Custom…** model entry stay in the existing model seam.
- Reordered the guided source and visual hierarchy to Name/Goal, lead/model,
  budget/deadline, Allowed CLIs/models, and Start. The goal pane now precedes
  a 4 pt gutter and 300 pt rail, with its 420 pt minimum and a 52 pt footer
  pinned outside advanced-content scrolling.
- Moved New Ensemble, graph, and run-detail tabs to the WP-00 shared
  `AttachedWorkbenchTab`; no route, close, launch, grant, probe, auth,
  worktree, handoff, or model-resolution behavior was modified.
- Added source and behavior contracts in the WP-60-owned test files. No
  reusable platform nuance beyond the existing WP-00 canvas/accessibility
  contract was discovered, so no reference note or reference-index row is
  intended. ADR 0018 and ADR 0022 remain unchanged.

## Goal-mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-60's goal-first Rafu New Ensemble composer and attached graph/run
detail canvases, representing every CLI/model relationship once while
preserving all orchestration behavior; verify and commit it locally."

You are in the dedicated worktree on branch codex/presentation-ensemble. Use
gpt-5.6-terra with xhigh reasoning.

Read AGENTS.md; the execution README; WP-00; WP-60;
pre-initial-push-workbench.md; the named parent-plan sections; ADR 0018 and ADR
0022; conductor/README.md; C8-coordinator-ux.md;
conductor/ensemble-manual-test-plan.md; ensemble-onboarding.md; the hierarchy
vocabulary in settings-surface.md; and skill-routing.md. Use
swiftui-expert-skill and macOS swiftui-patterns.

Run `git status --short --branch`. Stop unless this is
codex/presentation-ensemble, clean, the initial `git rev-parse HEAD` equals the
coordinator-supplied exact `<FOUNDATION_SHA>`, and the Runs source-contract
tests have been split out of EnsembleStartCanvasTests. Touch only WP-60-owned
paths. Do not edit ConductorRunsPanelView, WorkspaceSession, orchestration
domain/adapters/stores/launchers, shared styles, Package.swift, or shared
indexes.

Apply the shared attached tab to New Ensemble, graph, and run detail. Reorder
New Ensemble in actual source order: Name/Goal, lead/model, budget/deadline,
Allowed CLIs/models, Start. Use the 420 pt goal, 4 pt gutter, and 300 pt rail.
Rename the icon grid to a compact selection list and show each CLI/model once.
Make lead single-select and Allowed multi-select, keep explicit unavailable
reasons, inherited/custom model truth, the one-pane goal, fixed footer, and
inline disabled reason. Change no grant, auth, probe, process, worktree,
handoff, launch, or routing behavior. Add no user-facing “Conductor” string.

Add the exact tests and manual/accessibility matrix in WP-60. Use the single
Rafu Lightning GUI lease or report precise deferrals.

Complete all changes before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change afterward. When holding the single GUI lease, run
`./script/build_and_run.sh --verify` and complete the manual matrix; otherwise
report the exact deferral. Stage only owned paths and create one local commit.
Do not push, merge, open a PR, or publish. After green gates and the successful
commit, remove only this dedicated worktree's `.build`; never remove the
primary checkout's cache. Report delivered behavior, SHA, renamed/changed
paths, gates, source/order and behavior evidence, theme/VoiceOver/larger-text
results, ADR/reference updates, deferred checks, risks, any intended
reference-index row, and the next dependency (merge WP-60 after WP-50 and
before WP-90). Complete the Goal only after commit and handoff.
```
