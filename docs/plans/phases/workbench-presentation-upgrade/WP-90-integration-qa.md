# WP-90 — Integrated craft audit, regression gate, and documentation close-out

## Status and execution slot

- **Status:** Planned.
- **Wave:** 2; serial after WP-10 through WP-60 are merged.
- **Suggested branch:** `codex/presentation-integration-qa`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Required base:** exact `<POST_WAVE_1_SHA>`.
- **Merge requirement:** final branch in this presentation set.

## Goal

Prove that the six independently implemented surfaces form one coherent,
theme-owned workbench, fix only genuine integration defects, run the full
theme/display/accessibility/multi-window matrix, and make every plan, decision,
reference, and index describe the implemented state.

WP-90 is not a license to redesign a lane. Route a defect back to its original
branch when practical. Make a direct production edit only when reopening the
fan-out would be disproportionate and the correction is small, cross-lane, and
fully called out.

## Required reading and skills

Read:

- `AGENTS.md`
- every file in this execution folder
- the complete parent `workbench-presentation-upgrade.md`
- ADR 0002, 0004, 0012, 0014, 0016, 0018, and 0022
- `docs/plans/phases/pre-initial-push-workbench.md`
- `docs/references/ui-design-language.md`
- `docs/references/settings-surface.md`
- `docs/references/ensemble-onboarding.md`
- `docs/plans/phases/conductor/ensemble-manual-test-plan.md`
- every new reference note reported by a lane
- `docs/references/build-and-run.md`
- `docs/references/skill-routing.md`

Use `swiftui-expert-skill` with the relevant macOS, layout, accessibility,
focus, view-structure, and performance references. Use Build macOS Apps
`swiftui-patterns`, `build-run-debug`, and `window-management`.
Use `appkit-interop` for any TextKit/SwiftTerm/split/window issue. Use the root
`swift-concurrency-pro` only if an unexpected integration fix crosses actor or
async state; presentation work should not.

## Ownership

WP-90 owns:

- `Tests/RafuAppTests/ThemedControlStyleScanTests.swift`
- new `Tests/RafuAppTests/WorkbenchPresentationIntegrationTests.swift`
- `docs/plans/phases/workbench-presentation-upgrade.md`
- every `WP-*.md` status/implementation record in this execution folder
- `docs/plans/phases/workbench-presentation-upgrade/README.md`
- `docs/plans/phases/README.md`
- `docs/plans/phases/pre-initial-push-workbench.md`, only if this pass becomes
  part of its achieved gate
- `docs/references/ui-design-language.md`
- `docs/references/settings-surface.md`
- `docs/references/ensemble-onboarding.md`
- `docs/plans/phases/conductor/ensemble-manual-test-plan.md`
- `docs/references/README.md`
- `docs/decisions/README.md`
- lane-created reference notes, only for factual integration corrections

It may edit merged production/test files only for a documented integration
defect. It must not add scope, change process behavior, introduce a theme key,
edit `Package.*`, or silently rewrite a lane. Any production correction appears
as its own handoff subsection with symptom, owner, reason it was integrated
here, tests, and manual evidence.

## Integration procedure

### I1. Audit the merge base and owned paths

Before UI review:

1. Confirm WP-00 and all six Wave 1 commits are ancestors of HEAD.
2. Compare each branch commit to `<FOUNDATION_SHA>` and verify its changed paths
   match its plan.
3. Confirm no Wave 1 branch changed another lane's plan, source, tests, shared
   styles, `Package.*`, or shared indexes.
4. Confirm removed/renamed files have one replacement and no stale source
   reference:
   - `SettingsPaneStrip.swift` →
     `SettingsPaneNavigation.swift`
   - `EnsembleCLIIconGrid.swift` →
     `EnsembleCLISelectionList.swift`
5. Confirm the terminal-manager commit precedes the utility-panel commit in the
   integrated history.

Stop on an ownership violation or unresolved merge marker.

### I2. Run focused cross-lane tests

Update the global themed-control scan to the implemented component names and
ensure it still guards actual system-accent leaks rather than prose.

Add integration contracts that pin:

- exactly one workbench deck;
- every required document/canvas tab host consumes the shared attached-tab
  primitive;
- every utility mode has exactly one primary header and a close path;
- terminal tile and manager row consume one shared border resolver;
- Settings and Ensemble use the same compact semantic geometry without
  duplicating each other's components;
- no mask/clip reaches TextKit or SwiftTerm hosts;
- no hard-coded presentation color, provider-color chrome, new JSON key,
  shadow, blur stack, or decorative focus/tab animation was introduced;
- no new user-facing “Conductor” string.

Do not replace behavioral tests with broad source scans. These checks supplement
the lane suites.

### I3. Reconcile only union defects

Exercise the merged surfaces before editing. Likely union seams to inspect:

- WP-10 deck plus WP-40 solid utility surface;
- WP-20 terminal tile plus WP-30 current manager row;
- WP-30 terminal header after WP-40 removes the old outer header;
- WP-40 Runs/New Run plus WP-60 New Ensemble/graph/detail tabs;
- WP-50 and WP-60 large-text behavior beside the same utility width;
- global style scan after renamed Settings/Ensemble components.

If a fix is required, make it in the smallest original owner file and add a
regression test. Re-run the affected focused lane gate before continuing.

### I4. Complete the integrated visual matrix

Record content size in points and `backingScaleFactor`. Keep screenshots outside
the source tree unless the user explicitly asks to commit visual artifacts.
This is orthogonal axis coverage, not a Cartesian product. Before capture,
write a numbered manifest where every shot lists the axes/states it proves;
the completed manifest must cover every item below at least once without
manufacturing thousands of redundant combinations.

Required theme states:

- Indigo
- Khadi
- GitHub Light
- imported exact `workbench-converged-surfaces.json`

Required geometry/state axes:

- window widths: 900 pt editor-constrained, 1,200 pt normal, 1,440 pt wide;
- display scale: 1× and 2×;
- editor topology: single, 1×2, 2×1, 2×2, 1+2;
- tabs: one, overflow, dirty, exited terminal, long title, hover, pressed,
  selected, focused, inactive;
- terminals: uncolored, preset, background-matching custom, current/background,
  focus, attention;
- utilities: Search empty/results, Source Control no-repo/clean/changes,
  Terminals empty/list, Ensemble empty/list;
- Settings: all seven panes, regular/compact, native fallback;
- Ensemble: ready/unavailable, inherited/custom, empty/filled goal,
  disabled/enabled Start;
- user text: default and largest supported accessibility size for tabs, panel
  headers, Settings navigation/sections, provider rows, helper copy, and empty
  states;
- controls: rail buttons, tabs, provider rows, and terminal rows in
  rest/hover/pressed/selected/disabled states with immediate feedback;
- windows: two workspaces, key/inactive, normal/full-screen/restored, independent
  splits/sidebar/utility/settings/tabs/terminal focus, one top band.

Annotate at least one 1× and one 2× capture with deck inset, complete
splitter-inclusive group gap, hairline, tab seam, and terminal perimeter.
Preflight the available displays before beginning. If no display reports a
true 1× `backingScaleFactor`, record the missing hardware state and arrange an
external 1× display/user check. Geometry unit tests may support that deferral
but do not replace real 1× evidence; the set cannot be marked complete until
the 1× manifest item is attached.

### I5. Complete accessibility and interaction

- Full Keyboard Access from Files through tabs/editor/utilities/rails/status.
- VoiceOver: no duplicate panel nouns; tab selection, unique current terminal,
  Settings headings/groups, and Ensemble single/multi selection/order.
- Increase Contrast: essential boundaries strengthen and remain non-color.
- Reduce Transparency: solid surfaces remain legible.
- Reduce Motion: no new decorative tab, focus, pane, terminal, caret, or typing
  motion.
- Larger user text: tabs/panel headers/settings navigation/provider rows/helper
  copy expand, wrap, or overflow without losing essential actions.
- Splitter, tab drag/reorder/split, TextKit focus/scroll/selection, SwiftTerm
  input/scroll/hide/close/teardown, Search, Git, branch popover, Settings
  retention, and Ensemble launch remain functional.

### I6. Close documentation before the final gate

Update:

- ADR/index status and relationship to ADR 0012;
- parent phase status with implementation commits and evidence;
- every child plan with commit/result/deferred record;
- execution README status and final merge order;
- `ui-design-language.md` to the implemented deck/group/tab/panel grammar;
- `settings-surface.md` to adaptive navigation and retained custom section
  semantics;
- `ensemble-onboarding.md` and
  `conductor/ensemble-manual-test-plan.md` to remove the obsolete 3/12
  icon-grid-first, centered-form, duplicated model-picker, and stale disclosure
  expectations;
- active pre-initial-push phase if the user accepts this as part of its gate;
- reference index rows for real lane discoveries.

Use a preliminary full test run to obtain the test total before writing final
evidence. Documentation is complete before the final sequence. If any evidence
must change afterward, rerun the complete final sequence.

## Final verification

Ensure no other SwiftPM command owns this worktree's build lock. Run, in order:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
./script/test.sh --no-parallel
./script/build_and_run.sh --verify
```

No source or documentation file changes after `./script/test.sh`. The later
serial test and launch are read-only gates. If anything changes, restart at
format.

Review warnings, run `git diff --check`, validate all Markdown links and owned
source/test paths, and inspect the final diff for hard-coded colors, new theme
keys, unrelated behavior, generated products, and secrets.

Commit the integration result locally, do not push, and, after green gates and
the successful commit, remove only this dedicated worktree's `.build`; never
remove the primary checkout's cache.

## Set-level acceptance

- Built-in themes show depth without shadow/hard-coded color; converged user
  surfaces retain ownership through geometry and semantics.
- Deck/gutters/radii match the parent metrics within one physical pixel.
- Attached tabs visibly join content and remain selected in grayscale.
- Terminal identity surrounds the actual pane; neutral structure survives a
  color collision; manager current state is unique.
- Utility nouns appear once and creation empty states form one family.
- Settings and Ensemble put common tasks before advanced controls.
- No process, I/O, Git, Search, terminal lifecycle, orchestration, credential,
  or theme-schema behavior changed.
- Both test modes, build, lint, launch, manual, and accessibility gates are
  complete.

## Goal-mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Integrate and audit the complete Rafu workbench presentation upgrade from the
merged WP-00/WP-10/WP-20/WP-30/WP-40/WP-50/WP-60 commits, fix only genuine
union defects, complete the full visual/accessibility regression matrix, close
the documentation, verify, and commit the final integration locally."

You are in the dedicated worktree on branch
codex/presentation-integration-qa. Use gpt-5.6-sol with high reasoning.

Read AGENTS.md; every document under
docs/plans/phases/workbench-presentation-upgrade/; the complete parent
workbench-presentation-upgrade.md; ADRs 0002, 0004, 0012, 0014, 0016, 0018,
0022; pre-initial-push-workbench.md; ui-design-language.md;
settings-surface.md; ensemble-onboarding.md;
conductor/ensemble-manual-test-plan.md; all lane-created reference notes;
build-and-run.md; and skill-routing.md. Use the required
SwiftUI/macOS/build/window/AppKit skills.

Run `git status --short --branch`. Stop unless this is
codex/presentation-integration-qa, clean, the initial `git rev-parse HEAD`
equals the coordinator-supplied exact `<POST_WAVE_1_SHA>`, and all seven
implementation commits are ancestors of HEAD. Audit every lane against
`<FOUNDATION_SHA>` before editing; an overlap or forbidden path is a blocker,
not a merge choice.

Run focused cross-lane tests, update the global themed-control scan, and add the
integration contracts in WP-90. Exercise the merged UI before fixing anything.
Route defects back to their owner when practical; if a small union fix must land
here, document symptom, owner, rationale, exact edit, and proof. Add no feature,
theme key, hard-coded product color, process behavior, or Package.swift change.

Complete every theme, width, 1x/2x, topology, tab, terminal, utility, Settings,
Ensemble, two-window, fullscreen/restoration, keyboard, VoiceOver, Increase
Contrast, Reduce Transparency, Reduce Motion, and larger-text state in WP-90.
Treat these as orthogonal coverage and keep a numbered capture manifest mapping
shots to axes. Include complete control-state coverage and independent sidebar,
utility, settings, tab, split, and terminal-focus state in the two-window pass.
If no true 1x display is available, do not claim completion: record the
external-display/user-check dependency and leave the Goal active until that
evidence is supplied.
Use only Rafu Lightning. Keep visual artifacts outside the repo unless the user
explicitly asks to commit them.

Run a preliminary full suite, then update all plan/decision/reference/index
records before the final gate. Final order:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
./script/test.sh --no-parallel
./script/build_and_run.sh --verify
No file may change after the parallel test. If it does, repeat the sequence.
Run git diff --check and validate Markdown links/paths.

Stage only the audited integration and documentation changes and create one
local commit. Do not push, merge, open a PR, release, or publish. After green
gates and the successful commit, remove only this dedicated worktree's
`.build`; never remove the primary checkout's cache. Report delivered behavior,
final SHA, all merged commits, changed paths, exact gate results and test total,
warning count, numbered visual/accessibility manifest, ADR/reference updates,
any union fixes, documented nuances, remaining risks/deferred user checks, the
next integration dependency, and set-level acceptance. Complete the Goal only
after the green commit and handoff.
```
