# Ensemble guided onboarding ("New Ensemble…")

## Applies to

The `EnsembleStartCanvas` opened by ⌘⇧E, the Rafu menu, the command palette,
and the Runs panel's header button
(`Sources/RafuApp/Views/EnsembleStartCanvas.swift`): its three doors, the
guided (Door 1) CLI gating, budget-grant defaults, and per-CLI model choice,
the template (Door 2) instantiation reuse, and the expert (Door 3)
workflow-launch reuse. It does not change `ConductorEnsembleGrant`,
`ConductorWorkflowLibraryModel`, `ConductorWorkflowLaunchModel`, or
`ConductorConcurrentRunCoordinator` — this canvas is a caller of all of them,
never a second implementation.

M01 additionally covers the model-carrying seams the canvas feeds:
`ConductorCoordinatorLauncher`'s `providerModelDefaults` parameter and
`ConductorEnsembleRequestService`'s child-run model resolution. The grant
itself is deliberately untouched — see "Which model, on which CLI" below.

## Last verified

- 2026-07-27
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`)
- macOS 26.5.2 (25F84), arm64

## The three-door contract

One canvas, one `EnsembleDoor` segmented picker, guided preselected
(C8-coordinator-ux.md "Three doors, one default"):

| Door | Purpose | Reused code path |
|---|---|---|
| **Describe a Goal** (default) | Plain-language goal + CLI + budget grant → a live coordinator terminal | `ConductorCoordinatorLauncher.start(provider:model:goal:grant:label:providerModelDefaults:in:)` |
| **From a Template** | Copies one bundled agent/workflow file set into `.rafu/` | `ConductorWorkflowLibraryModel.instantiate(templateID:scope:replaceConfirmed:)` + its `pendingReplacement` confirmation dialog, lifted into this canvas unchanged |
| **Existing Workflow** (expert) | Launches an already-authored workflow | `ConductorWorkflowLaunchModel` + `session.conductorConcurrentRuns.start(_:launcher:)`, exactly as `ConductorRunsPanelView`'s `ConductorNewRunCanvas` already does |

Door switching has no transition animation — a `switch` inside a plain
`Group`, not a `withAnimation` — so there is nothing to suppress for Reduce
Motion; it was simply never added.

## Canvas host and navigation contract (UX-01)

`EditorCanvasRoute` owns two creation routes: `.ensembleStart` and
`.ensembleNewRun`. Both sit below blame, standalone diff, graph, and run
detail, and above the editor fallback. That defensive precedence is normally
unreachable because `WorkspaceSession` activators make all four Ensemble
canvases mutually exclusive before clearing the document selection.

Both creation canvases:

- render a normal editor-style tab strip with a visible close button;
- close on Esc through `onExitCommand`, with no sheet `.cancelAction`;
- fall back to the last open document exactly like
  `closeConductorRunDetail()`;
- are window-scoped because every window owns its own `WorkspaceSession`.

**UX2-02 supersedes UX-01's centered 600 pt measure for New Ensemble only.**
The New Run canvas (`ConductorNewRunCanvas`) still clamps to 600 pt; the New
Ensemble canvas is now full editor width. See "The New Ensemble layout" below.

The general surface rule established here is: **configuration surfaces are
editor tabs; modals are reserved for destructive confirmations.** The
template-conflict `confirmationDialog` therefore remains deliberate — it is a
safety prompt, not a configuration surface.

The Runs header's Graph, New Ensemble, and New Run actions use
`RafuIconButtonStyle`. Each has a help tooltip and explicit accessibility
label, while the same actions remain available from the Rafu menu and command
palette. New Ensemble's four entry paths all call the same
`WorkspaceSession.showEnsembleStart()` seam; New Run's panel, menu, and palette
paths call `showEnsembleNewRun()`.

## The New Ensemble layout (UX2-02)

One full-width canvas, five stacked bands: tab strip, header, door content,
footer bar. The header carries the title, the **name field**, and the door
picker; the footer carries the inline error, Close, and the primary verb.

Door 1's content is **two columns, no centered measure**:

| Column | Width | Contents |
|---|---|---|
| Left rail | 3/12 of the canvas, clamped to 280…420 pt | Coordinator icon grid + model picker, budget grant (steppers, deadline), allowed-CLI icon grid + one model picker per allowed CLI |
| Right pane | the remainder | `EnsembleGoalPane` — the live-Markdown goal surface |

The fraction is the layout; the clamp is the safety rail.
`EnsembleStartCanvas.controlsWidth(inTotal:)` is `nonisolated static` and pure
precisely so the split is unit-testable without a window
(`guidedColumnSplit`). Below ~1120 pt the floor wins and the goal pane simply
takes less; above ~1680 pt the cap wins so the rail never eats a wide display.

Doors 2 and 3 are single full-width columns (Door 3's `Form` keeps a 720 pt
reading measure — a grouped form stretched to 2000 pt is unreadable, and this
is a form, not a writing surface).

### The goal is ONE pane, not an editor/preview split

`EnsembleGoalPane` is a plain-text Markdown editor while focused and the
rendered document when not; click, the header's pencil/eye action, or the
VoiceOver "Edit goal" action puts the caret back, and clicking away renders.
Two properties make this shape the right one rather than a nicety:

1. **The goal stays plain `String`.** It is pasted verbatim into a CLI prompt
   (see "The paste-fallback rule is universal" below), so a rich-text or
   attributed editor here would be a correctness bug. The renderer is
   read-only and never writes back; `goalStaysPlainTextThroughTheMarkdownPane`
   pins that the launcher receives the typed Markdown byte for byte, with only
   outer whitespace trimmed.
2. **Zero Markdown work on the typing path.** Because only one face is on
   screen at a time, there is no parse, no debounce, and no per-keystroke
   re-render. `MarkdownPreviewView`'s `.split` mode needs a 200 ms trailing
   debounce for exactly the reason this pane does not: there, both halves are
   live at once.

**Focus nuance worth reusing.** Setting `@FocusState` in the same update that
inserts the `TextEditor` is silently dropped — the target view does not exist
yet. `EnsembleGoalPane` hops once (`.task(id: isEditing)` → `await
Task.yield()` → `isEditorFocused = true`) rather than sleeping. The
click-away transition is guarded on the **true→false edge**
(`onChange(of:) { wasFocused, isFocused in ... }`); an unguarded `!isFocused`
check cancels the edit on the editor's own unfocused first frame.

Markdown presentation is shared, not copied: `RafuMarkdownStyling`
(`Sources/RafuApp/Markdown/RafuMarkdownStyling.swift`) holds the theme text
colors, table treatment, code-block card, and Tree-sitter highlighter, and
both `MarkdownPreviewView` and this pane apply it via `.rafuMarkdownStyling()`.
Per-document concerns (`baseURL`, `imageBaseURL`, the local-file image
provider) stay at the preview's call site — the goal pane has no document and
therefore no directory to resolve relative images against.

### Both CLI pickers are icon grids

`EnsembleCLIIconGrid` + `EnsembleCLIIconCard` replace the old row list and the
old column of toggles. Same component, two modes: `.selected` (coordinator,
single-select) and `.allowed` (grant, multi-select). Icons come from
`ConductorCLIIcons.icon(for:)` — the shared seven-provider catalog, consumed
here, never re-derived.

Selection is stated **three ways** so it never depends on color: a filled
`checkmark.circle.fill` badge, a 2 pt border (vs. 1 pt hairline), and a
semibold label. An unavailable CLI stays **visible and disabled** with an
`exclamationmark.circle.fill` badge, and its reason — which the old row list
showed inline and a grid cell has no room for — is preserved in BOTH `help`
(pointer) and `accessibilityLabel` (VoiceOver). The reason is bounded in the
layout, never dropped; a disabled card with no stated reason would be the
regression to watch for.

### Which model, on which CLI (M01)

The canvas showed *which CLI* but never *which model*: the coordinator had a
free-text field labelled "Provider default", and the allowed-CLI grid had no
model at all. Three things changed, and one deliberately did not.

**1. Every card names its model.** `EnsembleCLIIconCard` gained an optional
`detail`/`detailHelp` pair, rendered as one truncated line under the CLI name
and restated in full in both `help` and `accessibilityLabel` — the same
bounded-never-dropped discipline `reason` already used. The coordinator's card
shows `ConductorModelResolution.label`; each allowed card shows its own.

**2. The model field is a picker that still accepts anything.**
`EnsembleModelField` (coordinator + one per allowed CLI) lists "CLI default",
the catalog, and a "Custom…" item that reveals a text field. A custom value
already set is listed back as a selectable row — a picker that dropped a
hand-typed id would lose the user's choice on the next selection. This is
required, not a nicety: `ConductorModelResolution` deliberately accepts an
unknown id.

**3. Per-CLI models are carried ALONGSIDE the grant, never inside it.**
`ConductorEnsembleGrant.allowedProviders` crosses into RafuCore and is enforced
as a *permission* (ADR 0018; violation is exit 77). A model is a launch
*preference* — declining it changes which model runs, never whether the run is
authorized. Widening the grant to carry it would conflate the two and expand a
security-reviewed contract for a display feature. The defaults ride on
`ConductorCoordinatorSession.providerModelDefaults` instead, a Rafu-side record
the child process never sees (it still receives only the opaque token).
`ConductorEnsembleRequestService.applyModelDefaults(to:payload:workspace:)`
reads them back via the request's own token → `coordinatorID` →
`session.conductorCoordinatorSessions`.

The child-run chain is `role.model` → this Ensemble's per-provider default →
Settings → Agents → nothing, through the one shared resolver. It is applied
**after** `--role` overrides (an override is the coordinator's explicit per-run
choice and must outrank an ensemble-wide preference) and **inside**
`resolveRunDefinitions`, so the plan-gate re-parse inherits identical
semantics rather than a second implementation.

**Cross-vendor safety, restated for two shapes.** The coordinator's single
field still resets unconditionally in `selectProvider(_:)`. The per-CLI models
need no such guard because they are *keyed by CLI*: a value stored under Codex
is unrepresentable as Claude Code's, which is the structural version of the
same rule. De-allowing a CLI drops its entry, so re-allowing re-inherits from
Settings instead of resurrecting a stale pick.

**Honesty nuance worth reusing.** `selectProvider` prefills the Settings
default *into* the coordinator field. Passing that prefilled value to the
resolver as `explicit:` would report `.explicit` for a choice the user never
made, so `coordinatorModelResolution` hands it over as `settingsDefault:` when
it still equals the stored default. The same reasoning is why allowing a CLI
seeds no per-CLI model at all: pre-filling an inherited value turns it into a
claimed pick. Generalises to any surface that prefills a default and then
reports where a value came from — a prefill is not a decision.

`ConductorModelCatalog` (merge curated+discovered, classify a stored string as
known or `.custom`) was extracted from `ConductorSettingsTab`'s two inline
methods, which now delegate to it; nothing else in `Settings/**` changed. The
canvas deliberately consumes **curated only** — discovery runs the user's CLI,
and opening this canvas must not, the same rule that keeps probing out of
`EnsembleStartModel.init`.

### Naming an Ensemble

The header's name field flows into the **existing** label seams, not a new
parallel field:

| Door | Seam | Already rendered by |
|---|---|---|
| 1 (guided) | `ConductorCoordinatorSession.label`, via `ConductorCoordinatorLauncher.start(..., label:)` | `ConductorGraphCanvas` (coordinator node title), `ConductorRunsPanelView.startedByLabel` |
| 3 (expert) | `ConductorWorkflowRunRequest.label` → `ConductorRunManifest.label` | `ConductorGraphModel` (run node title), `ConductorRunsPanelView` |

`ConductorCoordinatorSession.label` is additive (`var` with a `nil` default,
so the synthesized memberwise init accepts every existing call site) and
`displayTitle` falls back to `goal` — pre-UX2-02 behaviour for any coordinator
without a name.

Blank means "use the suggestion", and the placeholder **shows** the
suggestion, so there is no such thing as an unnamed Ensemble and no hidden
default. `EnsembleStartModel.deriveName(from:)` takes the first line with
words, strips Markdown structure (`#`, `-`, `*`, `+`, `>`, `1.`) and inline
emphasis, and bounds it to 60 characters on a word boundary; with no such
line it falls back to `"Ensemble <timestamp>"`. The timestamp string is
memoized (`cachedTimestampName`) because `suggestedName(for:)` is called from
`body` on every goal keystroke and date formatting is the only non-trivial
work in it.

## Door 1: CLI gating reuses the Agent Terminal picker's own policy

`EnsembleStartModel.probeCLIs(workspaceRoot:)` calls
`AgentTerminalLaunchService(workspaceRoot:adapters:defaultModelStore:).options()`
— the exact resolve-then-`authStatus()` mapping the Agent Terminal picker
(AT-01) already uses — rather than re-implementing probe/auth classification.
One policy, read twice: `AgentTerminalOption.isReady` gates Door 1's CLI rows
identically to the Agent Terminal sheet's rows, so the two pickers can never
silently drift apart.

A CLI is enabled only when `isReady` (installed AND authenticated-or-unknown,
matching the adapter contract's "unknown never blocks a run" rule).
`AgentTerminalLaunchService.options()` maps BOTH `.authenticated` and
`.unknown` to `.ready`, which is byte-identical to the launch-time re-check
inside `ConductorCoordinatorLauncher` — the same two-case mapping written
once per side, deliberately, so the canvas cannot enable a CLI the launcher
would then refuse (or vice versa). `.unknown` being launchable is intentional
policy for delegated-auth CLIs, not a gap.

**The policy is shared; the strings are not.** Because each surface names its
own action, the disabled-reason copy is intentionally NOT equal across
surfaces, and a diff of the strings is not evidence of drift:

- Only the **not-authenticated** hint is verbatim-shared (it is the adapter's
  own vendor text).
- **Not-installed** wording is per-surface by design.
- **`.unknown`** shows an explicit explanation in Settings → Agents but no
  reason at all in this canvas, because here it is simply ready.

A
disabled row always carries a stated reason (glyph + text via
`Label(_:systemImage:)`, never color alone) and the same text appears in its
`accessibilityLabel`:

- **Not installed** — Door 1 uses its OWN wording ("Not installed — install
  this CLI to use it as a coordinator.") rather than reusing the Agent
  Terminal sheet's literal string, which names a different feature ("...to
  open an Agent Terminal."). The underlying classification is identical; only
  the display copy differs per calling context.
- **Not authenticated** — the adapter's own `hint` text is shown VERBATIM,
  never rewritten (AGENTS.md: an adapter's sign-in instruction is the vendor's
  own words).

Probing happens ONLY from the canvas's `.task(id: session.rootURL...)`, never
from `EnsembleStartModel.init` — opening the canvas must never probe the
user's machine behind their back, mirroring `ConductorSettingsModel`'s own
rule ("opening Settings must never probe").

## Grant defaults and where they surface

The budget grant (C8-coordinator-ux.md "The consent model") is always visible
in Door 1's form, under its own "Budget grant" section — never buried in
Settings, never a hidden default:

| Grant field | Default | UI control |
|---|---|---|
| `maxConcurrentChildRuns` | 3, clamped to `session.conductorConcurrentRuns.activeLimit` | Stepper, captioned "Capped at N per window" |
| `maxTotalChildRuns` | 12 | Stepper |
| `allowedProviders` | Every CLI that probed ready (ADR 0018: a coordinator cannot reach a vendor the user did not authorize) | Multi-select icon grid (`EnsembleCLIIconCard`, `.allowed` mode), seeded once per probe, all changes through `setAllowed(_:for:)` |
| `deadline` | None | Picker: 1 hour / 4 hours / 8 hours / no deadline |
| `usageCeilingPercentPoints` | `nil` (out of v1 UI) | Not exposed — see Follow-ups |

`EnsembleStartModel.makeGrant(windowCap:)` is pure and synchronous: it clamps
`maxConcurrentChildRuns` to `min(maxConcurrent, windowCap)` so the canvas can
never promise more concurrency than `ConductorConcurrentRunCoordinator`
(C6) will actually honor, and maps the deadline choice through an injected
clock (`Date.init` by default, a fixed closure in tests).

## The paste-fallback rule is universal, not conditional

**No agent CLI Rafu supports accepts an initial-prompt argument.** This is
the single highest-value fact in this note. `AgentTerminalLaunchShape`
(`Sources/RafuApp/Terminal/AgentTerminalLaunchService.swift`) is the only
place argv for an interactive agent CLI is composed, and
`arguments(model:)` returns exactly `interactiveArguments` plus an optional
`[modelFlag, model]` pair — nothing else. `AgentTerminalLaunchShape.forCLI(_:)`
defines no prompt form for **any** of the seven CLIs (Claude Code, Codex,
OpenCode, Cline, Kimi, Gemini CLI, Cursor CLI). `ConductorCoordinatorLauncher.start`
passes that shape's argv straight through, so the goal text provably never
reaches the child process: `EnsembleCoordinatorLaunchTests` asserts
`!spec.arguments.contains(coordinator.goal)`. Rafu never
synthesizes terminal input, so the copyable-goal confirmation row
(`EnsembleStartCanvas.launchConfirmation`) is shown **after every successful
guided launch**, unconditionally — it is not gated on a per-CLI capability
check, because none currently exists to gate on. If a future CLI gains a
verified prompt argument, the seam to extend is
`AgentTerminalLaunchShape.forCLI(_:)`/`.arguments(model:)`, not this canvas —
and only at that point does a per-CLI capability check become meaningful.
Do not add a "does this CLI take a prompt?" branch to the canvas while the
answer is uniformly no; it would be dead code that reads as a live policy.

### Close timing (a deliberate two-phase flow)

`EnsembleStartModel.start(in:)` launches the coordinator and, on success,
sets `postLaunchGoalToPaste` — but the canvas **stays open** on the
confirmation row (goal text + Copy + "Done") instead of instantly closing.
Only `finishAndShowGraph(in:)` — the Done button's action — calls
`session.showConductorGraph()`, which clears
`session.ensembleStartCanvasVisible`. This is intentional: the copyable goal
is the ONLY way the user gets their plain-language intent into the
coordinator's terminal for the CLIs available today, so it must never be a
toast the user could miss behind an instantly-replaced canvas.

The launcher reveals the new coordinator terminal as part of starting Door 1.
Ordinary terminal reveal clears both creation canvases, but
`beginEnsembleStartLaunch()` / `endEnsembleStartLaunch()` narrowly retain the
start canvas during this internal reveal. Without that guard, the form
disappears before `postLaunchGoalToPaste` can render; with it, a user who
explicitly closes the canvas during launch still keeps it closed.

## Door 2: template reuse, and the one deferred seam

Door 2 hardcodes `scope: .repository` (the plan's own wording is "Add to This
Repository"; no scope picker) and calls `ConductorWorkflowLibraryModel`
exactly as `ConductorRunsPanelView` does, including lifting its
`confirmationDialog` for `pendingReplacement` verbatim — the same
conflict-confirmation policy, not a second copy of it. On success it opens
the template's workflow file as an editor tab via `session.open(_:)`.

**Deferred by explicit coordinator decision:** switching the Runs panel to
its "Workflows" tab after a successful Door 2 instantiation. That tab
selection is `ConductorRunsPanelView`'s own private `@State private var
section`, not a `WorkspaceSession` property, and the decision was not to
invent a new session-level seam for it this phase. Today the user sees the
newly-created file open as a tab; they must click into the Runs panel and its
Workflows tab themselves to see it listed there. Follow-up: expose a
`WorkspaceSession`-level "requested panel section" seam (or move workflow
navigation state onto the session) so a future caller — Door 2 among
others — can request a specific panel tab, not just panel visibility.

## Two defect classes caught in review (patterns, not one-offs)

Both were found by read-only review of this canvas, and both generalise to any
future Rafu form that prefills per-provider defaults or gathers consent.

**1. A per-provider default prefilled with `if field.isEmpty` leaks one
vendor's value across a provider switch.** The model-identifier field was
initially seeded only when empty, so switching the coordinator CLI left the
previous vendor's model string in place and would have launched CLI B with
CLI A's model. The correct pattern is the **unconditional reset** already used
by `AgentTerminalSheet.select(_:)`: on provider change, overwrite the field
from the newly selected provider's default, empty or not. Fixed here by
routing all provider changes through `EnsembleStartModel.selectProvider(_:)`
rather than binding the picker straight to the stored property. Rule: an
`isEmpty` guard is correct for "don't clobber what the user typed" only when
the default does not depend on another control's value; as soon as it does,
the guard becomes a cross-contamination bug.

**2. A consent control that can reach the empty set produces a coordinator
that silently refuses every child run.** The grant's "Allowed CLIs" toggles
could all be switched off, yielding `allowedProviders == []`. Nothing in the
UI objected, the coordinator launched normally, and then every child run was
rejected with **exit 77** by `ConductorEnsembleGrant`'s authorization check —
a failure visible only inside the coordinator CLI's own output, where Rafu
shows the user nothing. Rule: any consent surface whose selection can become
empty needs a non-empty guard on its primary action, because "authorized for
nothing" is indistinguishable from a broken product from the user's seat.

## Door 3: expert reuse

Door 3 embeds `ConductorWorkflowLaunchModel` exactly as
`ConductorNewRunCanvas`'s workflow mode does (same `load`/`selectWorkflow`/
`resolvedRoles`/`modelValue`/`makeRequest()` calls), and its `expertCanStart`
computed property is a line-for-line mirror of that canvas's own `canStart` —
deliberately checking the LOCAL task-prompt `@State` rather than
`ConductorWorkflowLaunchModel.canStart`, because the model's own `taskPrompt`
is only synced into it immediately before `makeRequest()`; reading the
model's property here would disable the button on a stale empty string.

The cap guard is `session.canStartConductorWorkflowRun` directly — no
reimplementation — and its disabled-reason caption reuses
`ConductorConcurrentRunError.activeLimitReached(limit:).errorDescription`
rather than writing a second copy of that message.

## Follow-ups (recorded, not built this phase)

- **Usage-ceiling UI.** `ConductorEnsembleGrant.usageCeilingPercentPoints`
  stays `nil` from this canvas; C7's per-step usage deltas make a percentage
  ceiling meaningful, but no editor for it exists yet. Honesty over knobs:
  the field is real in the grant type, just not user-editable here.
- **Editable defaults in Settings.** Max concurrent/total run defaults, the
  default deadline choice, and the default allowed-CLI set are all currently
  in-canvas-only state (reset each time the canvas opens fresh). A Settings →
  Ensemble surface to persist personal defaults is future work, not required
  for the guided door to be usable today.
- **Door 2 → Workflows tab.** See "Door 2" above.
- **Door 2 re-derives the instantiated file path** instead of reading it back
  from the reloaded library after `instantiate(...)` returns. Correct against
  today's template layout, but it encodes that layout in a second place: if a
  template's file arrangement changes, this door would open a blank editor tab
  with no error. Prefer having the library report the paths it actually wrote.

## Verification

```bash
swift test --filter EnsembleStartCanvasTests
swift test
swift test --no-parallel
swift build
./script/build_and_run.sh --verify
./script/format.sh --fix
./script/format.sh --lint
rg -n 'keyboardShortcut\("e"' Sources/RafuApp/App/RafuAppCommands.swift
rg -n '\.keyboardShortcut\(' -o Sources/RafuApp/App/RafuAppCommands.swift | sort | uniq -c
```

UX2-02 adds `guidedColumnSplit` (the 3/12 fraction and both clamps),
`goalStaysPlainTextThroughTheMarkdownPane` (the launcher receives the typed
Markdown byte for byte), `ensembleNameDerivation` (structure stripping,
bounding, the memoized timestamp fallback, typed-name precedence),
`cliPickersAreIconGrids`, and `goalPaneIsSinglePane`. It also rewrites
`canvasCloseAndWidthContract`'s New Ensemble half: that canvas is now asserted
to NOT carry `.frame(maxWidth: 600` and to carry the two-column split instead.
The New Run canvas's half of that test is unchanged.

M01 adds `coordinatorCardNamesItsModel`, `coordinatorCardNamesNoModelWhenUnset`
(the resolver's refusal to guess, read through this surface),
`perCLIModelsAreIsolated`, `blankPerCLIModelFallsThrough`,
`ConductorModelCatalogTests`, and `childRunModelPrecedence` in
`EnsembleMutatingVerbTests` — the full role → Ensemble → Settings → nothing
chain asserted against the manifest's step binding, plus a `--role` override
outranking the Ensemble default.

`EnsembleStartCanvasTests` covers the CLI gating matrix, grant defaults/
clamping/deadline mapping, the guided door's goal-required guard, a
spy-verified launch success (registers a coordinator session, then Done
flips the canvas-closed/graph-visible flags), a launch failure (canvas stays
open, nothing registered), Door 3's cap guard equality with
`session.canStartConductorWorkflowRun`, Door 2's clean-instantiate and
conflict-then-confirm paths via `ConductorWorkflowLibraryModel` directly, and
the command seams' `descriptor == nil` guard. UX-01 adds route replacement,
last-document fallback, second-window independence, terminal replacement,
entry-point/no-sheet, readable-width/Esc, and header
accessibility/equivalent-command coverage.

⌘⇧E collision: no enumerating test (impractical against
`RafuAppCommands`'s declarative `Button` list). Verified by inspection
(`rg -n '\.keyboardShortcut\(' -o Sources/RafuApp/App/RafuAppCommands.swift`):
the in-use ⌘⇧-modified letter set before this change was `n` (New Workspace
Window), `l` (Select All Occurrences), `k` (Delete Line), `p` (Command
Palette), `f` (Search Workspace), `g` (Show Source Control), and `a` (New
Agent Terminal, AT-01). ⌘⇧E was free and is now New Ensemble.

## Related code, ADRs, and phases

- `Sources/RafuApp/Views/EnsembleStartCanvas.swift`
- `Sources/RafuApp/Views/EnsembleGoalPane.swift`
- `Sources/RafuApp/Views/EnsembleCLIIconGrid.swift`
- `Sources/RafuApp/Views/EnsembleModelField.swift`
- `Sources/RafuApp/Conductor/ConductorModelResolution.swift`
- `Sources/RafuApp/Conductor/ConductorModelCatalog.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleRequestService.swift`
- `Sources/RafuApp/Markdown/RafuMarkdownStyling.swift`
- `Sources/RafuApp/Conductor/ConductorCLIIcons.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift` (`ensembleStartCanvasVisible`,
  `ensembleNewRunCanvasVisible`, `showEnsembleStart()`,
  `showEnsembleNewRun()`)
- `Sources/RafuApp/App/RafuAppCommands.swift`
- `Sources/RafuApp/Views/CommandPaletteView.swift`
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleGrant.swift`
- `Sources/RafuApp/Conductor/Library/ConductorWorkflowLibraryModel.swift`
- `Sources/RafuApp/Conductor/Library/ConductorWorkflowLaunchModel.swift`
- `Sources/RafuApp/Terminal/AgentTerminalLaunchService.swift`
- [`ensemble-consent-and-token.md`](ensemble-consent-and-token.md)
- [`agent-terminals.md`](agent-terminals.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)
- [`C8-coordinator-ux.md`](../plans/phases/conductor/C8-coordinator-ux.md)
- [`C8-07-guided-onboarding.md`](../plans/phases/conductor/C8-07-guided-onboarding.md)
