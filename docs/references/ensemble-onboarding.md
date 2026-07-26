# Ensemble guided onboarding ("New Ensemble…")

## Applies to

The `EnsembleStartSheet` opened by ⌘⇧E, the Rafu menu, the command palette,
and the Runs panel's header button
(`Sources/RafuApp/Views/EnsembleStartSheet.swift`): its three doors, the
guided (Door 1) CLI gating and budget-grant defaults, the template (Door 2)
instantiation reuse, and the expert (Door 3) workflow-launch reuse. It does
not change `ConductorCoordinatorLauncher`, `ConductorEnsembleGrant`,
`ConductorWorkflowLibraryModel`, `ConductorWorkflowLaunchModel`,
`ConductorConcurrentRunCoordinator`, or the Ensemble request service — this
sheet is a caller of all of them, never a second implementation.

## Last verified

- 2026-07-26
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`)
- macOS 26.5.2 (25F84), arm64

## The three-door contract

One sheet, one `EnsembleDoor` segmented picker, guided preselected
(C8-coordinator-ux.md "Three doors, one default"):

| Door | Purpose | Reused code path |
|---|---|---|
| **Describe a Goal** (default) | Plain-language goal + CLI + budget grant → a live coordinator terminal | `ConductorCoordinatorLauncher.start(provider:model:goal:grant:in:)` |
| **From a Template** | Copies one bundled agent/workflow file set into `.rafu/` | `ConductorWorkflowLibraryModel.instantiate(templateID:scope:replaceConfirmed:)` + its `pendingReplacement` confirmation dialog, lifted into this sheet unchanged |
| **Existing Workflow** (expert) | Launches an already-authored workflow | `ConductorWorkflowLaunchModel` + `session.conductorConcurrentRuns.start(_:launcher:)`, exactly as `ConductorRunsPanelView`'s `ConductorNewRunSheet` already does |

Door switching has no transition animation — a `switch` inside a plain
`Group`, not a `withAnimation` — so there is nothing to suppress for Reduce
Motion; it was simply never added.

## Door 1: CLI gating reuses the Agent Terminal picker's own policy

`EnsembleStartModel.probeCLIs(workspaceRoot:)` calls
`AgentTerminalLaunchService(workspaceRoot:adapters:defaultModelStore:).options()`
— the exact resolve-then-`authStatus()` mapping the Agent Terminal picker
(AT-01) already uses — rather than re-implementing probe/auth classification.
One policy, read twice: `AgentTerminalOption.isReady` gates Door 1's CLI rows
identically to the Agent Terminal sheet's rows, so the two pickers can never
silently drift apart.

A CLI is enabled only when `isReady` (installed AND authenticated-or-unknown,
matching the adapter contract's "unknown never blocks a run" rule). A
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

Probing happens ONLY from the sheet's `.task(id: session.rootURL...)`, never
from `EnsembleStartModel.init` — opening the sheet must never probe the
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
| `allowedProviders` | Every CLI that probed ready (ADR 0018: a coordinator cannot reach a vendor the user did not authorize) | Per-CLI toggle row, seeded once per probe |
| `deadline` | None | Picker: 1 hour / 4 hours / 8 hours / no deadline |
| `usageCeilingPercentPoints` | `nil` (out of v1 UI) | Not exposed — see Follow-ups |

`EnsembleStartModel.makeGrant(windowCap:)` is pure and synchronous: it clamps
`maxConcurrentChildRuns` to `min(maxConcurrent, windowCap)` so the sheet can
never promise more concurrency than `ConductorConcurrentRunCoordinator`
(C6) will actually honor, and maps the deadline choice through an injected
clock (`Date.init` by default, a fixed closure in tests).

## The paste-fallback rule is universal, not conditional

`ConductorCoordinatorLauncher.start` passes only
`AgentTerminalLaunchShape.arguments(model:)` to the spawned terminal — that
shape (`Sources/RafuApp/Terminal/AgentTerminalLaunchService.swift`) appends
only an optional model flag; **no currently supported CLI has an
initial-prompt argument form** (verified in `EnsembleCoordinatorLaunchTests`:
`!spec.arguments.contains(coordinator.goal)`, for every adapter). Rafu never
synthesizes terminal input, so the copyable-goal confirmation row
(`EnsembleStartSheet.launchConfirmation`) is shown **after every successful
guided launch**, unconditionally — it is not gated on a per-CLI capability
check, because none currently exists to gate on. If a future CLI gains a
verified prompt argument, the seam to extend is
`AgentTerminalLaunchShape.forCLI(_:)`/`.arguments(model:)`, not this sheet.

### Dismiss timing (a deliberate two-phase flow)

`EnsembleStartModel.start(in:)` launches the coordinator and, on success,
sets `postLaunchGoalToPaste` — but the sheet **stays open** on the
confirmation row (goal text + Copy + "Done") instead of instantly closing.
Only `finishAndShowGraph(in:)` — the Done button's action — calls
`session.showConductorGraph()` and clears
`session.ensembleStartSheetPresented`. This is intentional: the copyable goal
is the ONLY way the user gets their plain-language intent into the
coordinator's terminal for the CLIs available today, so it must never be a
toast the user could miss by an instantly-dismissing sheet.

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

## Door 3: expert reuse

Door 3 embeds `ConductorWorkflowLaunchModel` exactly as
`ConductorNewRunSheet`'s workflow mode does (same `load`/`selectWorkflow`/
`resolvedRoles`/`modelValue`/`makeRequest()` calls), and its `expertCanStart`
computed property is a line-for-line mirror of that sheet's own `canStart` —
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
  stays `nil` from this sheet; C7's per-step usage deltas make a percentage
  ceiling meaningful, but no editor for it exists yet. Honesty over knobs:
  the field is real in the grant type, just not user-editable here.
- **Editable defaults in Settings.** Max concurrent/total run defaults, the
  default deadline choice, and the default allowed-CLI set are all currently
  in-sheet-only state (reset each time the sheet opens fresh). A Settings →
  Ensemble surface to persist personal defaults is future work, not required
  for the guided door to be usable today.
- **Door 2 → Workflows tab.** See "Door 2" above.

## Verification

```bash
swift test --filter EnsembleStartSheetTests
swift test
swift test --no-parallel
swift build
./script/format.sh --fix
./script/format.sh --lint
rg -n 'keyboardShortcut\("e"' Sources/RafuApp/App/RafuAppCommands.swift
rg -n '\.keyboardShortcut\(' -o Sources/RafuApp/App/RafuAppCommands.swift | sort | uniq -c
```

`EnsembleStartSheetTests` covers the CLI gating matrix, grant defaults/
clamping/deadline mapping, the guided door's goal-required guard, a
spy-verified launch success (registers a coordinator session, then Done
flips the sheet-closed/graph-visible flags), a launch failure (sheet stays
open, nothing registered), Door 3's cap guard equality with
`session.canStartConductorWorkflowRun`, Door 2's clean-instantiate and
conflict-then-confirm paths via `ConductorWorkflowLibraryModel` directly, and
the command seam's `descriptor == nil` guard.

⌘⇧E collision: no enumerating test (impractical against
`RafuAppCommands`'s declarative `Button` list). Verified by inspection
(`rg -n '\.keyboardShortcut\(' -o Sources/RafuApp/App/RafuAppCommands.swift`):
the in-use ⌘⇧-modified letter set before this change was `n` (New Workspace
Window), `l` (Select All Occurrences), `k` (Delete Line), `p` (Command
Palette), `f` (Search Workspace), `g` (Show Source Control), and `a` (New
Agent Terminal, AT-01). ⌘⇧E was free and is now New Ensemble.

## Related code, ADRs, and phases

- `Sources/RafuApp/Views/EnsembleStartSheet.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift` (`ensembleStartSheetPresented`, `presentEnsembleStartSheet()`)
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
