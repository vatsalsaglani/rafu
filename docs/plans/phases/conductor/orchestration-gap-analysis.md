# Ensemble orchestration — target workflow vs. what C0–C7 built

- **Status:** Exploratory gap analysis (2026-07-25). No decision recorded;
  feeds a candidate C8 phase and an ADR 0018 amendment if pursued.
- **Prompted by:** the user's question after C5 — "how do we automate my
  actual manual loop (plan in one CLI, fan out to worktrees in others,
  merge back), not just run a pre-written pipeline?"

## The target workflow, decomposed

The user's manual loop today, as five capabilities:

1. **Dynamic planning** — hand one agent an initial doc; it *produces* the
   plan set (plans 1–6). The plan is an output of the run, not an input.
2. **Fan-out with dependencies** — run plans 1, 2, 3 in parallel worktrees;
   when 1 completes, start 4, 5, 6. A dependency DAG, not a line.
3. **Inline binding** — "for part X use Codex/gpt-5.6, for part Y use
   Claude/Fable" said in the kickoff message, not pre-authored in files.
4. **Agent-driven merge-back** — a coordinator agent verifies and merges
   completed branches, with the human above it, not inside every merge.
5. **Loop until done** — plan → build → review → fix → re-review, repeated
   across CLIs until the goal is met.

## What C0–C7 actually built

A **static, linear, human-gated pipeline executor** plus everything around
it: per-role CLI+model binding (files), delegated auth, Rafu-created
worktrees, per-step attempt-suffixed evidence, artifact-by-reference
passing, Revise-at-gate, one human merge gate, live terminal visibility,
usage-per-run deltas (C7), honest recovery (C7), concurrent independent
runs (C6). The workflow definition must exist *before* the run starts; steps
execute strictly in order; every consequential transition is a human click.

The structural fact: **Ensemble's engine executes; it never decides.** All
intelligence lives in the child CLIs (ADR 0018 — Rafu embeds no agent). The
user's target workflow requires a *deciding loop* somewhere.

Proof point: the Ensemble itself was built (C0–C7) by exactly the target
workflow — and the orchestrator was not Rafu. It was a coding agent
(Claude Code) with a loop, judgment, and tools, driving worktrees and
merges. Rafu's engine as shipped cannot replay that history.

## Capability-by-capability verdict

| # | Capability | Today | Verdict |
|---|---|---|---|
| 1 | Dynamic planning → executable plan | A planning step can *write* `.rafu/workflows/generated.md` + agent files as its artifact; a human then starts a second run from it. Nothing turns a plan artifact into steps of the SAME run. | **Gap** (workable two-run workaround) |
| 2 | Parallel steps / dependency DAG | Engine is strictly sequential. C6 gives concurrent *runs* — parallelism exists only if something external launches and stitches several runs. | **Gap** in-engine; achievable by an external driver over C6 |
| 3 | Inline per-part CLI/model binding | C6 adds per-run model override at launch for existing roles. Natural-language binding ("use X for Y") requires whoever interprets the sentence to write/patch role files — files stay the source of truth. | **Partial** |
| 4 | Agent-driven merge-back | Merge gate is deliberately human (ADR 0018 "gated merge-back"). A reviewer *role* can recommend in an artifact; only the user clicks Apply. | **Gap by design** — relaxing it is an ADR-level trust change |
| 5 | Loop until done | No loops, no retries beyond same-step, no conditionals in the grammar. | **Gap** |

Also not built (worth naming): mid-step agent↔agent conversation. Steps
communicate only via artifacts between steps; there is no channel for a
running implementor to ask the advisor a question. Today the "relay" is the
human at a gate.

## Two routes to close the gaps

### Route A — grow Rafu's engine into a workflow language

Add to the engine: parallel step groups, dependencies, a "plan gate" (a
step whose artifact IS a workflow file; the engine parses it, previews the
proposed steps, and a human gate approves expanding the current run),
loops/conditions.

- For: keeps Rafu the single control plane; all C7 observability applies
  automatically; deterministic and auditable.
- Against: Rafu grows a programming language; parallel *mutating* steps
  break the one-shared-worktree model (needs per-branch worktrees plus a
  merge strategy — the hardest part of the whole dream); and the engine
  still cannot *decide* — every adaptive choice must round-trip through an
  agent step or a human anyway.

### Route B — a coordinator agent drives; Rafu provides the substrate and cockpit

Make the orchestrator an external agent (Claude Code, Codex — the user's
choice), exactly like the manual loop today, but give it first-class tools:

- **`rafu ensemble` CLI verbs** over the existing CLI↔app IPC socket
  (ADR 0009 infrastructure): `run` (start a role/workflow), `status`
  (poll runs/steps/artifacts as JSON), `artifact` (read a handoff path),
  `await` (block until a run reaches a state), maybe `merge-request`
  (surface a diff to the human gate — never auto-apply).
- **A published skill/plugin** ("ensemble-with-rafu") for Claude Code and
  Codex teaching a coordinator agent the loop: plan → write role/workflow
  files → launch runs → await → stitch → request merges.
- **Rafu stays the cockpit:** every child run appears in the Runs panel and
  notch with usage deltas; every mutating merge stays behind the human
  diff gate; the coordinator itself runs visibly in a terminal tab.

- For: this is *provably* the right shape — it is how the Ensemble was
  built; infinitely flexible (DAGs, loops, judgment are the coordinator's
  problem); Rafu's engine stays small; ADR 0018 holds (Rafu still embeds
  no agent — the brain is an external CLI the user launched).
- Against: a new trust surface. Today "nothing executes without a visible
  user-initiated run"; a coordinator that starts child runs stretches that
  and needs an explicit consent model. Also depends on C6's concurrent
  runs and a hardened IPC surface.

### Recommendation

**Route B as the primary path, with one slice of Route A.** The coordinator
agent gets the loop, the DAG, and the judgment (it already has them); Rafu
gets `ensemble` verbs, the skill, and a consent model. From Route A, adopt
only the **plan gate** — it is cheap, human-gated, and makes the two-run
workaround for capability 1 a one-run experience. Defer in-engine parallel
step groups indefinitely; parallelism lives at the run level (C6) under the
coordinator.

## The trust model a C8 would need (ADR 0018 amendment)

- The user initiates the *coordinator* run visibly, granting it an explicit,
  bounded budget: max concurrent child runs, allowed CLIs/roles, optionally
  a token/usage ceiling (C7 metering makes this enforceable-ish, best
  effort and honest).
- Child runs started by the coordinator are labeled as such in the Runs
  panel ("started by run <id>"), never silent.
- Every mutating merge-back remains a human diff gate. The coordinator may
  *request* and *recommend*; it cannot apply.
- The IPC verbs authenticate as the same-user socket already does
  (ADR 0009) and never expose credentials, only run metadata and artifact
  paths.

## Explicit non-goals (unchanged)

Rafu still embeds no agent, holds no inference credentials, executes
nothing without a user-visible initiation, and never auto-commits. The
coordinator is always an external, user-installed, user-launched CLI.

## Related

- ADR 0018 (parent decision; a C8 pursuing Route B amends its consent
  language)
- ADR 0009 / `docs/references/cli-app-ipc.md` (the socket the verbs ride)
- `docs/references/conductor-pipeline-engine.md` (why the engine is a peer
  executor, not a brain)
- C6 (concurrent runs — the fan-out substrate), C7 (usage deltas — the
  budget substrate)
