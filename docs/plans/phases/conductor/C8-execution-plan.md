# C8 — Execution plan: seven worktree plans, four waves

- **Status:** Approved for execution (2026-07-26). Supersedes the "exploratory"
  status of the two C8 design docs for *scope*; they remain the design
  rationale. Prerequisite check: the three C6/C7 handoffs C8 depends on
  (concurrent GUI runs, usage persisted, recovery verbs) are **all closed on
  `main`** (`2da406e` + `5e2ac85`), so no substrate work precedes C8.
- **Design sources:** [`C8-coordinator-ux.md`](C8-coordinator-ux.md),
  [`C8-cli-and-skill-spec.md`](C8-cli-and-skill-spec.md),
  [`orchestration-gap-analysis.md`](orchestration-gap-analysis.md).

## Decisions locked for this execution (user-confirmed)

1. **`await` transport is STREAMING, not polling.** The IPC gains a
   long-lived subscription connection (`ensembleSubscribe`) carrying framed
   events with heartbeats. One-shot verbs keep the existing
   one-frame-per-connection contract. (C8-ux open question 2 — resolved.)
2. **Subcommand vs. path collision: strict.** `rafu ensemble …` with a
   filesystem entry named `ensemble` in the working directory refuses with
   `EX_USAGE` and tells the user to write `rafu ./ensemble`. Never guess.
   (Spec open question 6 — answered "we can be strict here".)
3. **Token lifetime: re-grant on relaunch.** Capability tokens are
   in-memory only and die with the app. A resumed coordinator must be
   re-granted by the user; read-only verbs (`status`, `artifact`, `await`)
   keep working without a token so a resumed coordinator can always
   re-orient itself. (Spec open question 7 — answered.)
4. **Coordinator runs in the user's checkout, interactively.** It is a
   visible, user-launched terminal session (D1: the terminal tab is the
   chat), not a worktree run and not manifest-backed in v1. Attribution
   survives durably through children's `startedBy`. (C8-ux open question 1.)
5. **One graph canvas per workspace**, grouping runs into coordinator trees
   via the new `startedBy` manifest field. (C8-ux open question 3.)
6. **Skill pack: bundled in the app, installed on demand** from Settings →
   Ensemble. (C8-ux open question 4.)
7. **Nested coordinators forbidden in v1** structurally: only coordinator
   sessions receive `RAFU_ENSEMBLE_TOKEN`; worker children never do, so a
   child cannot spawn. (C8-ux open question 5.)
8. **The graph canvas is interactive.** Clicking a node focuses its
   terminal session / opens its evidence; nodes carry the agent's icon
   (Claude Code, Codex, OpenCode, Cline, Kimi, Gemini, Cursor) as a small
   provider badge; gate nodes host the gate verbs.

## The seven plans

| # | Plan document | Branch | Wave | Prereq merges |
|---|---|---|---|---|
| 1 | [`C8-01-consent-adr-and-doc-hygiene.md`](C8-01-consent-adr-and-doc-hygiene.md) | `conductor/c8-01-consent-docs` | 1 | none |
| 2 | [`C8-02-ipc-streaming-and-readonly-verbs.md`](C8-02-ipc-streaming-and-readonly-verbs.md) | `conductor/c8-02-ipc-streaming` | 1 | none |
| 3 | [`C8-03-capability-token-and-mutating-verbs.md`](C8-03-capability-token-and-mutating-verbs.md) | `conductor/c8-03-mutating-verbs` | 2 | C8-01, C8-02 |
| 6 | [`C8-06-graph-canvas.md`](C8-06-graph-canvas.md) | `conductor/c8-06-graph-canvas` | 2 | C8-02 |
| 5 | [`C8-05-skill-pack-and-settings.md`](C8-05-skill-pack-and-settings.md) | `conductor/c8-05-skill-pack` | 2 | C8-01, C8-02 |
| 4 | [`C8-04-plan-gate-and-propose-merge.md`](C8-04-plan-gate-and-propose-merge.md) | `conductor/c8-04-plan-gate` | 3 | C8-03, C8-06 |
| 7 | [`C8-07-guided-onboarding.md`](C8-07-guided-onboarding.md) | `conductor/c8-07-onboarding` | 3 | C8-03, C8-06 |

Wave rules:

- **Wave 1** runs C8-01 (docs only), C8-02 (code), **and AT-01**
  (`conductor/at-01-agent-terminals`, see
  [`AT-execution-plan.md`](AT-execution-plan.md)) in parallel. AT-01
  owns the agent-icon catalog (`ConductorCLIIcons` + four SVGs + staging
  asserts) and the per-CLI interactive-launch probe table — C8-06 and
  C8-03 consume both. C8-02 and AT-01 touch disjoint regions of
  `ConductorCore.swift` and `WorkspaceSession.swift`; merge the two
  serially.
- **Wave 2** branches from `main` only after ALL wave-1 branches merged
  (C8-01, C8-02, AT-01). It runs **three** plans in parallel: C8-03,
  C8-06, and C8-05.

  C8-05 moved up from wave 3 (2026-07-26). Its only compile dependency on
  C8-03 was the Settings "Defaults card" reading `ConductorEnsembleGrant`;
  that card is now deferred (it was already scoped as read-only display,
  the lowest-value item in the plan). Everything else — the skill pack,
  the installer, the `Package.swift` resource line, the Settings pane's
  skill card — depends on nothing C8-03 builds. The verb *semantics* the
  skill teaches are fixed by the merged ADR 0018 amendment, not by
  C8-03's code, so the skill can be authored accurately now.

  Two consequences to hold: C8-03 must **bump
  `LauncherIPCProtocol.ensembleVerbVersion` to 2** when it lands the
  mutating verbs, and after C8-03 merges the coordinator re-checks the
  skill's `references/verbs.md` against the shipped
  `EnsembleArgumentParser` and `ensemble-ipc-verbs.md`, bumping the
  skill's `targetsVerbVersion` to match. Until then the skill documents
  mutating verbs the CLI will reject with exit 64, and
  `troubleshooting.md` says exactly that.

  C8-03 and C8-06 both edit `WorkspaceSession.swift`, at different anchored
  regions each plan names exactly. C8-05 touches neither that file nor any
  view, so it is disjoint from both by construction.
- **Wave 3** branches after wave 2 fully merged. C8-04 and C8-07 run in
  parallel; owned paths are disjoint (engine+gates / sheet+commands).
  Both require C8-03; C8-04 additionally requires C8-06 because the
  plan-gate preview reuses `ConductorGraphModel`, and C8-07 requires
  C8-06 because Start lands the user on the graph canvas.

## Why the ADR amendment is wave 1

`C8-cli-and-skill-spec.md` Part 4: "ADR amendment — must precede any
mutating code, not follow it." C8-02 ships only read-only verbs and the
streaming transport (zero new trust surface), so it may run parallel with
the amendment; C8-03 (token + mutating verbs) must not branch until C8-01
has merged.

## Worktree creation (coordinator, on `main`)

Commit the plan docs (and any pending doc edits) on `main` FIRST — a
worktree branch only contains what `main` has committed.

```bash
# Wave 1
git worktree add ../rafu-c8-consent   -b conductor/c8-01-consent-docs
git worktree add ../rafu-c8-ipc       -b conductor/c8-02-ipc-streaming
git worktree add ../rafu-at-terminals -b conductor/at-01-agent-terminals
# Wave 2 (after every wave-1 branch merges to main)
git worktree add ../rafu-c8-verbs   -b conductor/c8-03-mutating-verbs
git worktree add ../rafu-c8-canvas  -b conductor/c8-06-graph-canvas
git worktree add ../rafu-c8-skill   -b conductor/c8-05-skill-pack
# Wave 3 (after wave 2 merges)
git worktree add ../rafu-c8-plangate -b conductor/c8-04-plan-gate
git worktree add ../rafu-c8-onboard  -b conductor/c8-07-onboarding
```

Each plan document ends with a self-contained goal-mode prompt for the
agent working that worktree. The ground rules, preflight self-healing
table, handoff-not-halt rule, and merge protocol in
[`README.md`](README.md) apply to every plan unchanged, with one C8-wide
addition: **each agent commits locally on its branch and its final report
must include the branch name, every commit message, and the last commit id
(`git rev-parse HEAD`).**

## Shared-contract ownership (zero-conflict rule for C8)

| Shared file | Owned by | Everyone else |
|---|---|---|
| `Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift` | C8-02, then additive kinds by C8-03/C8-04 (post-merge, serial) | do not touch |
| `Sources/RafuApp/Conductor/ConductorCore.swift` | C8-02 (`startedBy`, `label`, `mergedAt`), AT-01 (`TerminalProcessSpec.agentProvider`, wave 1 parallel — disjoint region), C8-04 (`Gate.Kind.plan`, `Step.proposals`) — additive `var … ? = nil` only | do not touch |
| `Sources/RafuApp/Models/WorkspaceSession.swift` | AT-01 (terminal seam ~933, wave 1), C8-03 (coordinator-session seam), C8-06 (graph-canvas seam), C8-07 (sheet flag) — named anchors, additive | do not touch |
| `Sources/RafuApp/Views/ConductorRunsPanelView.swift` | C8-06 (wave 2), then C8-07 (wave 3, post-merge) | C8-03 must NOT touch it |
| `Sources/RafuApp/App/RafuAppCommands.swift`, `Views/CommandPaletteView.swift` | C8-06 (wave 2), C8-07 (wave 3) | C8-04 must NOT touch them |
| `Package.swift` | C8-05 only (one `.copy` resource line) | do not touch |
| `ensemble-manual-test-plan.md` | C8-05 extends §A, C8-06 appends §K, C8-04 appends §L, C8-07 appends §M — different regions of one file; append-only, serial merge | — |
| `docs/references/ensemble-ipc-verbs.md` | C8-03 appends the mutating verbs; C8-05 *mirrors* it into the skill but never edits it | C8-05 read-only |
| `script/build_and_run.sh` | AT-01 only (icon staging asserts — transferred from C8-06) | do not touch |
| `Sources/RafuApp/Conductor/ConductorCLIIcons.swift` + `Resources/FileIcons/` | AT-01 creates; C8-06 consumes | do not touch |

## Definition of done for C8 as a whole

1. A coordinator CLI, launched by the user from the New Ensemble sheet,
   can: check `status`, stream `await`, read `artifact`s, check its
   `grant`, `run` children (attributed, capped, token-gated), `note`,
   `abort` its own children, park a `--plan-gate` run for approval, and
   `propose-merge` — with the user approving every plan and merge gate in
   Rafu, and streaming (never polling) as the wait primitive.
2. A stray shell without a token can observe but never mutate (exit 77).
3. The graph canvas shows the whole tree live, one click from any node to
   its terminal or evidence, with per-agent icons and glyph+label states.
4. The skill pack installs from Settings and teaches exactly the shipped
   verb surface (verb version checked). **Coordinator step after C8-03
   merges:** re-check the skill's `references/verbs.md` against the
   shipped `EnsembleArgumentParser` and the now-complete
   `ensemble-ipc-verbs.md`, and bump the skill's `targetsVerbVersion`
   to 2. C8-05 authored it in parallel against the ADR, so this is the
   pass that makes doc and parser agree in both directions.
5. ADR 0018 carries the consent amendment; every stale doc noted in C8-01
   is fixed; `ensemble-manual-test-plan.md` gains sections K–M.
