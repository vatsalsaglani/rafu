# AT-02 — The Ensemble bridge: one sheet, terminal or coordinator

- **Status:** Ready. Branch: `conductor/at-02-ensemble-bridge` (from
  `main` AFTER AT-01 **and C8 wave 3** merged — verify
  `AgentTerminalSheet.swift`, `AgentTerminalLaunchService.swift`,
  `ConductorCoordinatorLauncher.swift`, `ConductorSkillInstaller.swift`,
  and `EnsembleStartSheet.swift` all exist; any missing ⇒ STOP and
  report which). AT-01 runs early (C8 wave 1); this bridge is the one
  AT plan that must wait for C8-03/05/07.

## Goal

Connect agent terminals to the Ensemble along the one honest seam:
**capability is decided at spawn.** The Agent Terminal sheet gains a
"Grant Ensemble coordination" toggle — off, the launch is AT-01's plain
tokenless terminal; on, the grant form appears and the launch routes
through `ConductorCoordinatorLauncher` (token minted, coordinator
session registered, user lands on the graph canvas). Because a live
process's environment cannot change, "promote this terminal" is
impossible — the bridge ships **"Relaunch as Ensemble Coordinator…"**
instead, and the UI says why. Both sheets cross-link so users always
find the other mode.

## Read first

`AGENTS.md`; conductor `README.md`; [`AT-execution-plan.md`](AT-execution-plan.md);
ADR 0018 + Amendment (token at spawn; grant consent); ADR 0021;
`Sources/RafuApp/Views/AgentTerminalSheet.swift` +
`Terminal/AgentTerminalLaunchService.swift` (AT-01);
`Sources/RafuApp/Views/EnsembleStartSheet.swift` (C8-07 — the grant
controls you extract); `Sources/RafuApp/Conductor/Ensemble/
{ConductorCoordinatorLauncher.swift,ConductorEnsembleGrant.swift,
ConductorSkillInstaller.swift}`; `swiftui-expert-skill`.

## Owned paths

- `Sources/RafuApp/Views/AgentTerminalSheet.swift` — toggle + grant form
  + coordinator routing + skill hint
- `Sources/RafuApp/Views/EnsembleStartSheet.swift` — replace its inline
  grant controls with the extracted shared form; add the cross-link row
- NEW `Sources/RafuApp/Views/EnsembleGrantForm.swift` — the extracted,
  shared grant controls (single source of the consent UI)
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift` — context
  menu "Relaunch as Ensemble Coordinator…" on agent-terminal rows
- NEW tests `Tests/RafuAppTests/AgentTerminalBridgeTests.swift`
- Docs: extend `docs/references/agent-terminals.md` (bridge section);
  `ensemble-manual-test-plan.md` NEW section **O**; this plan's status
  line. Intended index rows in the report.

**Forbidden:** engine files, `ConductorCore.swift`, the launch service's
plain-spec contract (you CALL it, you do not change its env rules),
`ConductorCoordinatorLauncher` internals (consume its API; a needed
signature change is a HANDOFF), `Package.swift`, Settings, commands/
palette (AT-01 already added the entries; the toggle lives in the
sheet), `EditorCanvasView.swift`, graph files.

## Design contract

### `EnsembleGrantForm.swift` (extraction, not invention)

Lift C8-07's grant controls (max concurrent stepper, max total stepper,
allowed-CLI toggles, wall-clock picker, captions) into one reusable
`struct EnsembleGrantForm: View` taking a `@Binding` to a small
`EnsembleGrantDraft` value (which both sheet models own) and the
available-CLI list. `EnsembleStartSheet` must render EXACTLY as before
the refactor — this is a pure extraction, verified by its existing
tests continuing to pass unchanged.

### The toggle (in `AgentTerminalSheet`)

- Off (default): AT-01 behavior byte-for-byte (regression test: spec
  env still exactly `["PATH"]`).
- On: reveal `EnsembleGrantForm` (allowed-CLIs seeded to ready ones,
  concurrent default 3); the goal field appears (coordinators get the
  goal; plain terminals don't have one) — reuse C8-07's copy rules,
  including the copyable-goal fallback for prompt-less CLIs; primary
  button retitles **"Start Coordinator"**; on launch call
  `ConductorCoordinatorLauncher.start(provider:model:goal:grant:in:)`,
  dismiss, `session.showConductorGraph()`. Failure keeps the sheet
  with the inline error, nothing spawned.
- A one-line footnote under the toggle: "Coordination is granted at
  launch — a running terminal can't be upgraded. Relaunch to change."
  (glyph + text, standard caption styling).
- Skill hint: when the toggle is ON, the chosen provider is
  `claudeCode`, and the skill is not installed (check via
  `ConductorSkillInstaller`'s classify path in a `.task`, never in
  `body`), show one inline row — "Coordinator skill not installed" +
  a "Open Settings" button (`SettingsLink` or the existing settings-
  opening pattern). Never blocks launch.

### Relaunch affordance (terminals panel)

Context menu on rows whose controller spec has `agentProvider`:
**"Relaunch as Ensemble Coordinator…"** → opens `AgentTerminalSheet`
prefilled (provider + model from the running session's spec) with the
toggle ON. It does NOT terminate the existing session — the copy is
"opens a new coordinator session"; closing the old one stays the user's
choice. Context menus never being the only path (AGENTS rule): the same
prefill is reachable from the sheet itself by picking the agent, so the
context menu is a shortcut, not the sole route.

### Cross-links

- `EnsembleStartSheet` guided door, bottom caption row: "Just want this
  agent in a terminal, no orchestration? **New Agent Terminal**" →
  closes this sheet, `session.presentAgentTerminalSheet()`.
- `AgentTerminalSheet` (toggle off), bottom caption row: "Want Rafu to
  coordinate parallel runs? Turn on Ensemble coordination above."

## Tests (`AgentTerminalBridgeTests.swift`)

- **Capability fork (load-bearing):** toggle off ⇒ launch-service spec,
  env exactly `["PATH"]`, no coordinator session registered; toggle on ⇒
  `ConductorCoordinatorLauncher` called (spy), token minted, coordinator
  session registered, `conductorGraphVisible == true`, sheet dismissed.
  One test asserts a plain launch NEVER passes through the coordinator
  path even when a grant draft was edited and the toggle turned back
  off.
- Grant-form extraction: `EnsembleStartSheet`'s existing model tests
  pass unchanged; `EnsembleGrantDraft` round-trips into
  `ConductorEnsembleGrant` identically from both sheets.
- Prefill: relaunch flow carries provider + model; toggle preset ON.
- Skill hint matrix: on+claudeCode+missing ⇒ hint; installed or other
  provider or toggle off ⇒ no hint; hint never disables Launch.
- Failure path: coordinator launch throw keeps sheet + error, zero
  sessions registered.

## Gates

`swift build` 0 warnings; `swift test` AND `swift test --no-parallel`
green; format `--fix`/`--lint` clean. HEADLESS ONLY — GUI checks for the
coordinator: toggle reveal (Reduce Motion: no animation), keyboard-only
pass across both sheets, context-menu path, cross-links.

## Documentation deliverables

Extend `docs/references/agent-terminals.md` with a "Bridge" section
(capability-at-spawn rule, why promotion is impossible, the relaunch
affordance, the single grant form as the one consent UI, skill hint
rule). `ensemble-manual-test-plan.md` section **O — Terminal ⇄ Ensemble
bridge** (O1 toggle off = plain terminal, O2 toggle on = coordinator on
the graph, O3 relaunch prefill keeps the old session, O4 skill hint
appears/never blocks, O5 cross-links navigate, O6 grant identical in
both sheets). Intended index rows in the report.

## Handoff report

Delivered behavior; changed paths; test evidence (call out the
capability-fork and extraction-invariance tests); GUI checks for the
coordinator; remaining risks; branch; every commit message;
`git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/at-02-ensemble-bridge. Preflight: run `git status
--short --branch` ONCE. On this branch + clean tree → proceed. Detached
HEAD or wrong branch + clean tree → checkout the branch if it exists,
else `git checkout -b conductor/at-02-ensemble-bridge main`, then
proceed and say so. Dirty tree with edits you did not make → STOP. Then
verify prerequisites: AgentTerminalSheet.swift and
AgentTerminalLaunchService.swift (AT-01), plus
ConductorCoordinatorLauncher.swift, ConductorSkillInstaller.swift, and
EnsembleStartSheet.swift (C8 wave 3) all exist. Any missing ⇒ STOP and
report which.

GOAL: implement docs/plans/phases/conductor/AT-02-ensemble-bridge.md —
the capability-at-spawn bridge between agent terminals and the
Ensemble: the "Grant Ensemble coordination" toggle in the Agent
Terminal sheet (off = AT-01's plain tokenless launch, unchanged; on =
grant form + ConductorCoordinatorLauncher + land on the graph), the
shared EnsembleGrantForm extracted from EnsembleStartSheet as a pure
refactor, the "Relaunch as Ensemble Coordinator…" context-menu
affordance (never terminates the old session), the cross-links between
the two sheets, and the non-blocking skill hint. The plan file is your
authoritative design contract, edit list, and test list — read it
FIRST, then AGENTS.md, the conductor README ground rules,
AT-execution-plan.md, ADR 0018+Amendment, ADR 0021, and the C8-03/05/07
APIs it names. Use swiftui-expert-skill.

HARD CONSTRAINTS: capability is decided at spawn and nowhere else — a
plain launch must provably never acquire a token and a granted launch
must provably route through ConductorCoordinatorLauncher (the
capability-fork tests are mandatory); the grant-form extraction changes
zero behavior in EnsembleStartSheet (its existing tests pass
unchanged); you consume the coordinator launcher's API — any needed
signature change is a HANDOFF with a proposed diff, not an edit; the
skill hint never blocks launching; the context menu is a shortcut,
never the only path; user-visible strings say Ensemble / Agent
Terminal. DO NOT touch engine files, ConductorCore.swift, the launch
service's env contract, coordinator-launcher internals, Package.swift,
Settings, commands/palette, EditorCanvasView, or graph files. HEADLESS
ONLY — list the GUI checks for the coordinator instead of launching.

DEFINITION OF DONE:
1. Capability fork test-proven both ways, including the
   toggled-on-then-off case spawning plain.
2. EnsembleGrantForm shared by both sheets; grant drafts map to
   identical ConductorEnsembleGrant values from either; C8-07's tests
   untouched and green.
3. Relaunch prefill works and preserves the running session; skill-hint
   matrix covered; failure path keeps the sheet with zero sessions.
4. swift build 0 warnings; swift test AND swift test --no-parallel
   green; format --fix + --lint clean.
5. agent-terminals.md bridge section written; manual-test-plan section
   O added; intended index rows in the report only.
6. Work committed locally in verified stages; never push/merge/rebase/
   checkout main.

FINAL REPORT (mandatory): delivered behavior; changed paths; test
evidence naming the capability-fork and extraction-invariance tests;
the GUI checks for the coordinator; remaining risks; branch name; every
commit message; last commit id from `git rev-parse HEAD`.
```
