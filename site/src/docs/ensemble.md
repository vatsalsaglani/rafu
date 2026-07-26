---
title: The Ensemble
description: Conduct the agent CLIs you already installed — plain-file agents and workflows, a worktree per mutating role, and a merge gate that is always yours.
badge: next beta
---

# The Ensemble

The Ensemble lets Rafu *conduct* the coding agents you already have instead of
asking you to pick one. An advisor on Claude, an implementor on Codex, a documentor
on Gemini — the CLIs you installed, the subscriptions you already pay for, each
doing the part it's best at, coordinated from one window.

It exists under two rules that nothing in the feature is allowed to bend:

- **Rafu embeds no agent.** It spawns the vendor CLIs you installed as child
  processes. There is no model client, no API-key field, and no inference inside
  Rafu — authentication stays in each vendor's own CLI, exactly where you left it.
- **Nothing runs without you.** Every run is a visible action you started, and work
  comes back to your checkout through a gate you open — never an event that happens
  to you.

## Agents and workflows are plain files

An **agent** is a Markdown file in `.rafu/agents/` — frontmatter for the provider,
model, autonomy, and handoff artifact; the body is the prompt:

```markdown
---
provider: claude
model: opus
autonomy: read-only
handoff: plan.md
---

Review the staged diff and write the plan for the mend.
```

A **workflow** is a Markdown file in `.rafu/workflows/` that orders agents into a
pipeline with gates between the steps. The files are the source of truth, so they
are committable, diffable, shareable, and usable without Rafu running at all — the
app's editors write these files, never a parallel database.

## A run, from weave to gate

Starting a workflow creates a **run**, and a run has a shape you can inspect:

- **Rafu creates the worktree; agents never do.** A mutating role works in a
  Rafu-created worktree on a `rafu/run-<id>` branch; read-only roles run against
  your checkout under the adapter's sandbox mapping. Autonomy inside the worktree is
  allowed precisely because the blast radius is bounded.
- **Handoffs are files, not stream parsing.** Each role writes its artifact to a
  Rafu-provided directory; a step completes when the artifact exists and the process
  exits cleanly. Captured output is evidence, not protocol.
- **Runs are repo data.** The manifest, per-step artifacts, patches, and logs live
  under `.rafu/runs/<id>/` — gitignored by default, committable if you choose.
- **Merge-back is a gate.** The worktree diff opens in the same side-by-side review
  canvas you already use; apply, commit, or discard is your click.

## Watching a run

- The **Ensemble** panel lists your runs; each opens a timeline canvas with every
  step, state, and artifact.
- **Show Ensemble Graph** (Rafu menu) projects the live manifest as a graph —
  roles as nodes, handoffs as edges, a plan-gate node where a coordinator's plan
  waits on you, and dashed ghost nodes for steps that have only been proposed.
- Live role output renders as real terminal tabs, and an active run surfaces in
  [the notch companion](/docs/notch-companion) with its step count.
- Every agent process is attributed as **Ensemble Agent** in Resources — never
  hidden inside Rafu's own number.

## The model question, answered once

Each adapter maps one vendor CLI: discovery, version probe, headless invocation,
autonomy flags, auth status, and **model selection** — curated defaults, dynamic
listing where the CLI supports it, and a free-text override when you know what you
want. One resolver answers *which model will actually run*, and the answer is shown
wherever the CLI is shown. When a vendor renames a flag, the adapter degrades to
*adapter needs update* instead of guessing.

The roster today: Claude Code, Codex, OpenCode, Cline, Kimi CLI, Gemini CLI, and
Cursor CLI — the last two on a best-effort tier that degrades honestly.

## Letting a coordinator drive

The advanced route: a CLI you launch *interactively* — say Claude Code in a terminal
tab — can drive runs itself through the [`rafu ensemble`](/docs/cli) verbs, with
Rafu's bundled skill pack teaching it the grammar. This is bounded by design:

- At launch you set a **grant**: maximum concurrent child runs (default 3), maximum
  total, the CLIs it may use, an optional usage ceiling, an optional deadline.
- The coordinator receives a **capability token** (`RAFU_ENSEMBLE_TOKEN`) that
  exists only in memory, dies with the app, and is re-granted by you after a
  relaunch. Worker agents never see it.
- A **plan gate** can hold the coordinator's fan-out plan for your approval before
  anything spawns, and `propose-merge` only ever *queues* a diff at your gate — it
  never merges.
- Exhaustion parks the coordinator and asks you; it never fails silently and never
  continues silently.

## Starting without writing files first

**New Ensemble…** (Rafu menu) opens a guided canvas that walks the three doors —
run a bundled workflow, assemble a run from your agents, or let a coordinator
drive — and *writes the `.rafu/` files for you*. The files are an output of the
flow, not a prerequisite for it.

## What it costs

- No credentials of any kind in Rafu — the adapter status is honest: *not logged in
  — run `codex login` in a terminal*
- Agent CLIs are child processes you started, attributed separately; Rafu's idle
  budget is untouched when no run is active
- A coordinator token unlocks no provider and no secret — it is a capability, not a
  credential

## What it will never do

- Hold, read, copy, or proxy a provider credential — subscription tokens and cookies
  are never reused for inference
- Execute anything without a visible, user-initiated run
- Merge, commit, or overwrite your checkout automatically
- Force-remove a worktree
- Write prompts, artifacts, or agent output to Rafu's own logs — they stay on disk
  in the repo, under `.rafu/runs/`

For one-off interactive use without a run, see [Agent terminals](/docs/agent-terminals).
For the wire a coordinator speaks, see [the `rafu` command](/docs/cli).
