# WP-74 — Terminal border hierarchy and shell picker

## Status and execution slot

- **Status:** Planned on 2026-07-30.
- **Wave:** Follow-up Wave 1; parallel with WP-71, WP-72, and WP-73.
- **Suggested branch:** `codex/presentation-terminal-hierarchy-picker`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Required base:** exact coordinator-supplied `<FOLLOWUP_BASE_SHA>`.
- **Issues closed:** WBP-005 and WBP-006.
- **Dependency:** all original presentation work through WP-60 is already in
  the base. This plan must finish before WP-90.

## Goal

Make user-selected terminal identity the visually authoritative perimeter while
keeping focus, current, attention, status, and neutral structure truthful; then
replace the Terminal Manager's nested shell submenu with a compact,
theme-coherent, keyboard- and VoiceOver-complete Rafu shell picker.

This lane changes presentation and selection UI only. Shell discovery,
preferred-shell fallback, process spawning, terminal lifetime, editor layout,
commands outside the Terminal Manager, and JSON theme schema remain unchanged.

## Required reading and skills

Read:

- `AGENTS.md`
- this plan and
  `docs/issues/workbench-presentation-follow-ups.md`
- `WP-20-editor-tabs-groups.md` and `WP-30-terminal-manager.md`
- ADR 0004, 0012, and 0022
- `docs/references/terminal-signals-and-shell-catalog.md`
- `docs/references/ui-design-language.md`
- `docs/references/skill-routing.md`
- every owned source/test file

Use the project-local `swiftui-expert-skill`, reading its latest-API,
accessibility, focus, and macOS popover/list references first. Use Build macOS
Apps `swiftui-patterns` for the picker, `appkit-interop` only if keyboard or
popover focus needs a narrow AppKit seam, and `build-run-debug` for staged
verification. Do not change concurrency or process code.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`, limited to the pure
  terminal-surface border resolver and its rendering geometry
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`
- new `Sources/RafuApp/Views/TerminalShellPickerView.swift`

### Test paths

- `Tests/RafuAppTests/RafuWorkbenchStyleContractTests.swift`, limited to
  terminal-border contracts
- `Tests/RafuAppTests/EditorTabAndGroupPresentationTests.swift`, limited to
  `matchingIdentityKeepsNeutralAndFocusedSignals`
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`
- new `Tests/RafuAppTests/TerminalShellPickerPresentationTests.swift`

### Lane documentation

- this plan's implementation record
- one uniquely named reference note only if a reusable macOS popover/focus
  nuance is proved

### Frozen and read-only

Do not edit:

- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/App/RafuAppCommands.swift`
- `Sources/RafuApp/Views/CommandPaletteView.swift`
- terminal engine, controller, shell catalog, store, process, and model files
- `Sources/RafuApp/Support/RafuMetrics.swift`
- `Sources/RafuApp/Support/RafuTheme.swift`
- `Sources/RafuApp/Support/RafuControlStyles.swift`
- theme JSON, `Package.*`, shared indexes, or another follow-up plan path

The app-menu `New Terminal With Shell` command remains unchanged. WBP-006 is
specifically the Terminal Manager header flow.

## Implementation contract

### T1. Preserve every terminal signal before changing emphasis

The shared pure resolver already represents:

- neutral structural edge;
- editor-group focus;
- manager-row current state;
- attention;
- optional user/session identity;
- background-matching identity fallback;
- normal and Increase Contrast environments.

Do not remove or collapse these meanings. Extend the resolver's output only as
needed to encode a clear nested perimeter hierarchy that both editor terminal
groups and manager rows consume.

### T2. Make identity the authoritative visible perimeter

For a terminal with an assigned identity:

- render the identity ring as the dominant 2-point inset perimeter;
- keep theme focus/current/attention structure present but subordinate as a
  separate 1-point outer perimeter or other non-overlapping resolver-defined
  edge;
- never draw the theme perimeter directly on top of and wider than identity;
- keep one current terminal semantically unique;
- preserve icon/text/status carriers so state remains understandable without
  color.

For a terminal without an identity:

- preserve the current focused editor perimeter strength;
- preserve manager current/attention behavior;
- preserve neutral structure.

For background-matching identity:

- keep the neutral fallback edge and non-color state carriers;
- do not synthesize a hard-coded replacement hue.

Increase Contrast must strengthen essential boundaries through the existing
pure environment input without reversing the hierarchy. Use only colors
resolved from the active JSON theme and optional session identity. Add no
required theme key.

The correction should propagate through existing
`rafuTerminalSurfaceBorder(...)` consumers. Do not edit `EditorCanvasView` to
special-case terminal tiles.

### T3. Replace the nested Terminal Manager menu with a split action

In the Terminal Manager primary header:

- keep a direct plus action that calls the existing
  `session.newTerminalTab()` path;
- when two or more shells are available, place an adjacent choose-shell
  affordance with an explicit accessibility label;
- open a Rafu-owned popover containing `TerminalShellPickerView`;
- on a single-shell machine, omit the redundant chooser;
- opening or navigating the picker performs no launch;
- explicit row selection calls the existing
  `session.newTerminalTab(shell:)` and dismisses.

The direct action preserves the current preferred-shell and `$SHELL` fallback
contract. Do not relabel it as an “OS default” and do not reimplement fallback.

### T4. Build a truthful shell picker

`TerminalShellPickerView` receives value data and callbacks:

- `[TerminalShell]`;
- selection callback;
- cancel/dismiss callback when necessary;
- only ephemeral keyboard/focus state.

Each row presents:

- shell name as primary text;
- exact executable path as secondary monospaced or secondary text, with a
  middle-truncation presentation that still exposes the full path to
  accessibility/help;
- a text chip such as `Default` when `isDefault` is true;
- selected/hover/focus/pressed states from existing theme roles.

Interaction:

- pointer click selects;
- Tab enters/leaves predictably;
- Up/Down move one row;
- Home/End may move to boundaries if implemented consistently;
- Return selects the focused row;
- Escape closes without spawning;
- opening gives a deterministic initial focus, normally the default row;
- VoiceOver announces shell name, full path, default status, position, and
  action;
- largest text expands rows/width within a bounded popover rather than clipping
  the only path truth.

Use stable shell path identity. Do not probe the system or spawn a process from
the view body. Do not add search unless measured shell counts prove the bounded
catalog unusable; the captured eight-row case does not.

### T5. Keep the existing app-menu path and process boundary

Do not change:

- `TerminalShellCatalog`;
- shell ordering/default computation;
- executable/path validation;
- `WorkspaceSession.newTerminalTab` overloads;
- terminal controller/process launch;
- command-menu shortcuts/submenus;
- agent-terminal launch behavior.

The new picker is a second presentation of the existing catalog, not a new
terminal authority.

## Tests

Expand the pure resolver matrix across:

- identity assigned/unassigned;
- focus current/background;
- manager current;
- attention;
- normal/Increase Contrast;
- background-matching identity;
- exact identity/theme widths and insets;
- non-overlap and draw order.

Add picker/panel coverage for:

- direct New Terminal invokes the default action exactly once;
- chooser appears only at two or more shells;
- opening, focus movement, and Escape spawn nothing;
- explicit pointer/Return selection passes the exact `TerminalShell`;
- default row/chip and stable ordering;
- full-path accessibility truth with long paths;
- keyboard boundary behavior and VoiceOver labels/values;
- larger text has a bounded vertical layout;
- no shell discovery/process calls originate from the picker body;
- manager rows and editor terminal tiles still share the resolver.

Run read-only terminal suites:

- `TerminalsPanelTests`
- `TerminalIdentityTests`
- `TerminalAttentionTests`
- `TerminalEditorTabTests`
- `TerminalShellCatalogTests`
- terminal process/teardown tests

## Manual acceptance

Using staged Rafu Lightning:

1. Show two split terminal editor tabs and the matching Terminal Manager rows.
2. Assign contrasting, similar, unassigned, and editor-background-matching
   identities. Move focus/current state between them and trigger attention.
3. Repeat in a key and inactive window, normal/Increase Contrast, 1×/2×.
4. Confirm exactly one current terminal and that identity remains readable
   without erasing theme structure/status text.
5. Test the header on one-shell, two-shell, and an eight-shell/long-path
   fixture.
6. Verify direct plus launch, chooser open/cancel, pointer selection, complete
   keyboard route, Return, Escape, VoiceOver, and largest text.
7. Confirm no terminal starts merely by opening or navigating the picker.
8. Cover all bundled themes and one imported user JSON theme.

Use only Rafu Lightning and the shared GUI lease.

## Verification and handoff

Run focused style/terminal/picker tests first. Final sequence:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Nothing may modify a tracked file after the parallel suite. Run
`./script/build_and_run.sh --verify` under the shared GUI lease, or report the
exact deferred visual/interaction states.

Run `git diff --check`, stage only owned paths, and create one local commit. Do
not push, merge, open a PR, publish, or release. After green gates and commit,
remove only this dedicated worktree's `.build`.

The handoff reports the resolver matrix/geometry, picker behavior, commit SHA,
paths, focused/full totals, staged/manual evidence, process-boundary proof,
warnings, deferred hardware states, any reference note, and WP-90 dependency.

## Implementation record

Pending. The implementor replaces this paragraph with the delivered resolver
and picker behavior, local commit SHA, exact verification evidence, deferred
manual states, warnings, and documentation-nuance classification before the
final lane gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-74 for Rafu: make terminal session identity visually
authoritative without losing focus/current/attention/neutral truth, replace
the Terminal Manager's nested shell menu with a keyboard- and VoiceOver-complete
Rafu shell picker, preserve shell discovery/process/lifetime behavior and JSON
theme authority, verify, and commit locally."

You are in a dedicated worktree on branch
codex/presentation-terminal-hierarchy-picker. Use gpt-5.6-sol with high
reasoning.

Read AGENTS.md, WP-74-terminal-hierarchy-picker.md, the follow-up issue ledger,
WP-20, WP-30, ADRs 0004/0012/0022,
terminal-signals-and-shell-catalog.md, ui-design-language.md,
skill-routing.md, and every owned source/test file. Use the project-local
swiftui-expert-skill with its latest-API, accessibility, focus, and macOS
popover/list references; use Build macOS Apps swiftui-patterns,
appkit-interop only if a narrow seam is required, and build-run-debug.

Run `git status --short --branch`. Stop unless the branch is exactly
codex/presentation-terminal-hierarchy-picker, the tree is clean, and the
initial `git rev-parse HEAD` equals the coordinator-supplied exact
`<FOLLOWUP_BASE_SHA>`. Work only in the terminal resolver portion of
RafuWorkbenchStyles.swift, WorkspaceTerminalsPanelView.swift, the new
TerminalShellPickerView.swift, the terminal portion of
RafuWorkbenchStyleContractTests.swift, TerminalManagerPresentationTests.swift,
the one `matchingIdentityKeepsNeutralAndFocusedSignals` contract in
EditorTabAndGroupPresentationTests.swift, the new
TerminalShellPickerPresentationTests.swift, and this plan record.
Treat EditorCanvasView, WorkspaceSession, RafuAppCommands, CommandPalette,
terminal catalog/controller/process/store/model files, shared metrics/theme/
control styles, theme JSON, Package.*, shared indexes, and every other lane as
read-only.
If implementation proves a reusable platform/toolchain nuance, you may add one
uniquely named note under docs/references as required by AGENTS.md; do not edit
the reference index, and report the intended WP-90 index row. Otherwise add no
documentation-only churn.

Extend the pure terminal-border resolver so an assigned identity is the
dominant 2-point inset perimeter while theme focus/current/attention structure
remains a separate subordinate 1-point edge. Preserve neutral structure,
one-current semantics, unassigned focused strength, attention/status
non-color carriers, background-matching fallback, and Increase Contrast.
Use only the active JSON theme and optional session identity; add no key or
hard-coded product color. Let existing editor/manager consumers receive the
fix; do not edit EditorCanvasView.

In the Terminal Manager header, keep direct New Terminal calling the existing
default action and add an adjacent chooser only for two or more shells. Replace
the nested submenu there with a Rafu-owned popover and new value-driven
TerminalShellPickerView. Show name primary, exact path secondary, and a Default
chip from isDefault. Stable path identity; deterministic initial focus;
pointer, Tab, arrows, Return, Escape, VoiceOver, and larger text. Opening or
navigating must never launch; only explicit selection passes the exact shell
to the existing session method and dismisses. Leave app-menu commands,
discovery, ordering/default logic, preferred/$SHELL fallback, process launch,
lifetime, and agent terminals untouched.

Add the complete resolver geometry matrix and picker action/no-spawn/
keyboard/accessibility/long-path tests. Run the read-only panel, identity,
attention, editor-tab, shell-catalog, and process/teardown suites named in the
plan. Manually cover split terminals plus manager rows; assigned/unassigned/
similar/background identities; focus/current/attention; key/inactive,
contrast, themes, 1x/2x; one/two/eight shells; direct/cancel/select/keyboard/
VoiceOver/largest-text states. Use only Rafu Lightning and the shared GUI
lease.

Final order:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change after the parallel suite. Then run the staged-app
verification if the lease is available and `git diff --check`.

Stage only WP-74-owned paths and create one intentional local commit. Do not
push, merge, open a PR, release, or publish. After green gates and the commit,
remove only this worktree's .build. Report resolver geometry, picker/process
behavior, commit SHA, changed paths, exact focused/full test results,
staged/manual/accessibility evidence, warning count, deferred hardware checks,
reusable nuances, remaining risks, and that WP-90 is next. Complete the Goal
only after the green commit and handoff.
```
