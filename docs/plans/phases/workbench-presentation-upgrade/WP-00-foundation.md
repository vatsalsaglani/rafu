# WP-00 — Presentation foundation and theme contract

## Status and execution slot

- **Status:** Implemented on `codex/presentation-foundation` (2026-07-29).
- **Wave:** 0; serial prerequisite for every visible lane.
- **Suggested branch:** `codex/presentation-foundation`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Base:** exact `<PLAN_SHA>` recorded from the committed
  `codex/workbench-presentation-parallel-plans` branch.
- **Merge requirement:** merge this plan before creating WP-10 through WP-60.

## Goal

Land the complete shared geometry, component, accessibility, and terminal-border
contract without changing a visible call site. Preserve the existing JSON
theme schema and prove that legacy/imported themes still decode.

Pasting this plan's Goal-mode prompt is also the explicit implementation
approval for ADR 0022. The implementor changes ADR 0022 from Proposed to
Accepted in the same foundation commit. Merely reading this plan is not that
approval.

## Required reading and skills

Read, in order:

1. `AGENTS.md`
2. [`README.md`](README.md)
3. [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md)
4. [`../workbench-presentation-upgrade.md`](../workbench-presentation-upgrade.md),
   especially durable presentation rules and P0
5. [`../../../decisions/0022-recessed-workbench-deck.md`](../../../decisions/0022-recessed-workbench-deck.md)
6. [`../../../decisions/0012-flat-workbench-chrome.md`](../../../decisions/0012-flat-workbench-chrome.md)
7. [`../../../references/ui-design-language.md`](../../../references/ui-design-language.md)
8. [`../../../references/skill-routing.md`](../../../references/skill-routing.md)

Use the project-local `swiftui-expert-skill`, reading its latest-API, layout,
view-structure, accessibility, and macOS references. Use Build macOS Apps
`swiftui-patterns` for the component contract. Do not use Liquid Glass.

## Exclusive ownership

The foundation worktree may edit only:

- `Sources/RafuApp/Support/RafuMetrics.swift`
- `Sources/RafuApp/Support/RafuControlStyles.swift`
- new `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`
- `Tests/RafuAppTests/RafuThemeTests.swift`
- new `Tests/RafuAppTests/RafuWorkbenchStyleContractTests.swift`
- new `Tests/RafuAppTests/Fixtures/workbench-converged-surfaces.json`
- `Tests/RafuAppTests/TerminalsPanelTests.swift`, only to move its
  `EditorCanvasView.swift` source contract
- `Tests/RafuAppTests/EditorThemeColorApplicationTests.swift`, as the destination for
  that editor-owned contract
- `Tests/RafuAppTests/Conductor/EnsembleStartCanvasTests.swift`, only to split
  assertions that source-scan other lanes
- new
  `Tests/RafuAppTests/Conductor/ConductorRunsPanelPresentationTests.swift`, as
  the destination for utility-owned source contracts
- a failing built-in token, only if the new contrast assertion proves it is
  necessary, in:
  - `Resources/Themes/indigo.json`
  - `Resources/Themes/khadi.json`
  - `Resources/Themes/dracula.json`
  - `Resources/Themes/notion-light.json`
  - `Resources/Themes/notion-dark.json`
  - `Resources/Themes/github-light.json`
  - `Resources/Themes/github-dark.json`
- `docs/decisions/0022-recessed-workbench-deck.md`
- `docs/decisions/README.md`
- this file's implementation record
- one uniquely named new reference note only if a reusable platform nuance is
  actually discovered

Do not edit any view call site, `RafuTheme.swift`, theme generation/import
services, `Package.*`, shared reference/phase indexes, the parent phase, or
another WP plan.

## Contract to implement

### F0. Accept the decision

- Change ADR 0022 to **Accepted** and update its row in the decision index.
- Do not widen the supersession: ADR 0012's theme authority, opaque chrome,
  native controls, no-glass rule, and `HSplitView` choice remain active.

### F1. Add the compact semantic metric tier

Add the parent plan's exact `RafuMetrics` constants:

- `workbenchInset = 4`
- `editorGroupGapTarget = 4`
- deck/group/tab/dense-selection/dense-card/field/popover radii of
  `6/5/4/4/6/5/8`
- utility body inset `8`
- settings section inset/row minimum/gap `14/36/28`
- terminal border/focused-border widths `1/2`

Do not change `radiusPanel`, existing tab/panel/status heights, editor font
metrics, or any persisted geometry.

### F2. Add the shared workbench primitives

Create focused `View` types and styles in `RafuWorkbenchStyles.swift` rather
than a monolithic modifier:

- `WorkbenchDeckSurface`
- `CornerCutoutOverlay`
- `AttachedWorkbenchTab` or one equivalently named attached-tab style
- `EditorGroupSurface`
- `TerminalSurfaceBorderStyle` with explicit
  `.editorGroup(isFocused:)` and
  `.managerRow(isCurrent:needsAttention:)` contexts
- `RafuUtilityPanelHeader`
- `RafuPanelEmptyState`
- `RafuSettingsSection`

The exact behavior is the parent plan's contract:

- all color inputs come from `RafuThemePalette`;
- no new JSON role and no hidden fallback color;
- corner cutouts and seam masks are overlay-only, non-hit-testing, and hidden
  from accessibility;
- no helper applies a mask or clip to arbitrary content;
- terminal output separates neutral structure, optional identity accent,
  focus/current/attention emphasis, and row fill;
- settings headers expose heading traits and containers preserve control
  reading order;
- text-bearing heights are minimums that can expand for larger user text;
- custom controls use `Button`, stable identity, native focus behavior, and
  immediate state changes without decorative motion.

If a generic container takes content, store the `@ViewBuilder` result as a view
value rather than a closure where practical.

### F3. Add the rail style

Add `RafuRailButtonStyle` to `RafuControlStyles.swift`:

- retain the existing 30 pt target;
- use the compact selection radius;
- represent selection with a close-fit themed wash, boundary, stronger
  icon/label, and a 2 pt deck-facing inset bar;
- expose selected, hover, pressed, disabled, inactive-window, tooltip, badge,
  and accessibility states without a hard-coded color;
- do not change `RafuIconButtonStyle` or apply the style at any call site.

### F4. Freeze theme compatibility

Create the exact converged-surface JSON fixture from the parent plan. Extend
theme tests to prove:

- the fixture decodes through the public theme path;
- surface convergence is not silently color-corrected;
- themes that contain only required legacy keys still decode;
- no new key is required;
- built-in normal-size primary and essential secondary text reaches 4.5:1
  against its immediate surface;
- essential icons, focus indication, and necessary control boundaries reach
  3:1;
- decorative hairlines are not incorrectly promoted to a contrast gate.

If and only if a bundled theme fails, fix the owning JSON token. Never add a
code-side contrast color or alter imported user themes.

### F5. Pure contract tests

`RafuWorkbenchStyleContractTests.swift` must pin at least:

- the semantic metric values;
- no content clipping/masking in deck/group helpers;
- non-hit-testing/accessibility-hidden corner overlays;
- attached-tab selected fill plus top/side/no-bottom geometry;
- context-aware terminal border precedence, including an identity color equal
  to the editor background;
- current, attention, identity, focus, and status remain distinct inputs;
- settings-section heading/group semantics;
- larger-text minimum-height policy rather than fixed clipping boxes.

Prefer pure resolvers and source-level contract checks already used by the
repository. Do not add screenshot-test infrastructure or a package dependency.

### F6. Decouple cross-lane source-contract tests

Move, without weakening, the terminal-tab vendor-mark source assertion from
`TerminalsPanelTests.swift` to `EditorThemeColorApplicationTests.swift`. After
WP-00, WP-20 can update the editor-owned source contract without editing
WP-30's manager suite.

Split `EnsembleStartCanvasTests.swift` so assertions that read
`ConductorRunsPanelView.swift`, `WorkspaceWindowView.swift`, app commands, or
the command palette live in the new
`ConductorRunsPanelPresentationTests.swift`. Split mixed assertions into an
Ensemble-owned half and a Runs-owned half rather than duplicating them. Keep
model, grant, goal, and composer-source contracts in
`EnsembleStartCanvasTests.swift`.

This is a test-ownership refactor only. Run the suite before and after, keep the
same behavior coverage, and do not edit production call sites. On foundation
merge, hand `EditorThemeColorApplicationTests.swift` to WP-20,
`TerminalsPanelTests.swift` to WP-30,
`ConductorRunsPanelPresentationTests.swift` to WP-40, and
`EnsembleStartCanvasTests.swift` to WP-60; those four files are not part of the
otherwise frozen WP-00 surface.

## Acceptance

- No visible call-site file changes.
- All existing built-in and imported-theme behavior remains compatible.
- The new converged fixture decodes without synthesized depth.
- No literal product color is introduced.
- The styles compile for Rafu's current macOS deployment target.
- ADR 0022 is Accepted and accurately indexed.

## Verification and handoff

Complete documentation before the final sequence:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

No staged-app launch is required when the plan changes no bundled theme token,
because it deliberately changes no visible call site. If a contrast failure
requires a bundled JSON-token correction, acquire the single GUI lease and
verify that theme in Rafu Lightning before handoff, or record that exact check
as deferred to the first coordinator merge round. Stage only owned paths,
create one local commit, do not push, and remove this worktree's `.build` after
the commit.

The handoff must include the foundation commit SHA. The coordinator merges it
and records the resulting integration SHA as `<FOUNDATION_SHA>` for all six
Wave 1 worktrees.

## Implementation record

- Added the complete semantic workbench metric tier, shared deck/tab/group,
  terminal-perimeter, utility, empty-state, Settings-section, and activity-rail
  presentation contracts without changing a visible call site or theme schema.
- Added pure/source contract coverage, the exact converged-surface fixture,
  legacy-theme compatibility coverage, and WCAG contrast gates for all seven
  bundled themes. Only failing existing tokens were corrected in their owning
  bundled JSON files.
- Moved the editor-terminal and Ensemble/Runs source contracts to their owning
  lane test files without weakening behavior coverage.
- Accepted ADR 0022 and indexed the deliberately narrow partial supersession of
  ADR 0012.
- No reusable platform nuance was discovered, so no reference note or reference
  index row is required. The exact gate results and local foundation commit SHA
  are recorded in the implementation handoff.

## Goal-mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-00, the shared presentation foundation for Rafu's workbench
upgrade, verify it, commit it locally, and provide the exact foundation SHA for
the parallel fan-out."

You are the WP-00 implementor in a dedicated Rafu worktree on branch
codex/presentation-foundation. Use gpt-5.6-sol with high reasoning.

Read completely, in order: AGENTS.md;
docs/plans/phases/workbench-presentation-upgrade/README.md;
docs/plans/phases/workbench-presentation-upgrade/WP-00-foundation.md;
docs/plans/phases/pre-initial-push-workbench.md;
docs/plans/phases/workbench-presentation-upgrade.md; ADR 0022; ADR 0012;
docs/references/ui-design-language.md; and
docs/references/skill-routing.md. Use the required SwiftUI and macOS skills.

Run `git status --short --branch`. Stop if this is not
codex/presentation-foundation, if the tree is not clean, or if the initial
`git rev-parse HEAD` is not the coordinator-supplied exact `<PLAN_SHA>`. Treat
this prompt as explicit acceptance of ADR 0022 and change its status to
Accepted.

Implement only the exact owned paths in WP-00. Add every shared metric, style,
pure resolver, accessibility contract, theme fixture, and test before any
visible lane starts. Do not edit a view call site, add a theme key, hard-code a
presentation color, or change Package.swift. If a built-in contrast test fails,
change only the failing token in its bundled theme JSON. If you believe another
shared contract is required, stop and report it instead of expanding scope.

Complete all source, tests, ADR, and any genuinely required reference note
before the final sequence:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may modify a file after the final parallel test.

Stage only WP-00-owned paths and create one intentional local commit. Do not
push, merge, open a PR, or publish. After green gates and the successful
commit, remove only this dedicated worktree's `.build`; never remove the
primary checkout's cache. Report delivered behavior, branch, commit SHA,
changed paths, exact gate results, theme/contrast results, ADR/reference
updates, risks, deferred checks, any intended reference-index row, and the next
dependency (coordinator merge and `<FOUNDATION_SHA>` recording). Mark the Goal
complete only after the commit and handoff are complete.
```
