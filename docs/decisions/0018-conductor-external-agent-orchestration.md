# ADR 0018: The Conductor — orchestrate external agent CLIs, embed none

- **Status:** Accepted (narrows the "embedded coding agent" initial non-goal)
- **Date:** 2026-07-24

## Context

Rafu's initial non-goals exclude an embedded coding agent. On 2026-07-24 the
user gave explicit direction to narrow that: Rafu should be able to run
multi-provider agent workflows — e.g. an advisor role on Claude, an
implementor role on Codex, a documentor role on Gemini — using the coding-agent
CLIs the user has already installed and paid subscriptions for. Today that
role pattern exists only inside Claude Code (`.claude/agents/*.md` +
orchestration skills), where every role is forced onto Claude models. No
harness lets a user bind roles to different vendors' subscriptions, and people
are hand-rolling exactly this composition.

The credential landscape shapes the design. Anthropic forbids reusing Claude
subscription OAuth tokens outside Claude Code; cookie-derived access (which
Rafu's usage tracking uses read-only for metering, ADR 0017) is fragile and
gray for inference. But every relevant vendor ships a headless CLI mode that
runs on the user's own login: `claude -p`, `codex exec`, `opencode run`,
`gemini -p`, `cursor-agent -p`, and equivalents from Cline and Kimi. Driving
the official CLI as a child process is using each product as intended, under
the user's own subscription, with zero credential handling in Rafu.

Rafu already owns every hard subsystem the feature needs: terminal sessions as
editor-tab peers with an attention pipeline (ADR 0004/0014/0016), git worktree
creation and removal (`GitService`, git-experience phase), editor-hosted
side-by-side diff review, a provider registry + settings pattern and per-vendor
usage metering (ADR 0017), and the notch companion. The Conductor is a thin
coordination layer over shipped machinery, not a new engine.

Alternatives considered:

1. **Embed an agent loop in Rafu calling model APIs with user API keys** —
   competes with the CLIs instead of composing them, excludes
   subscription-only capacity, and reverses the non-goal completely. Rejected.
2. **Reuse locally stored OAuth tokens / cookies for inference** — explicitly
   against Anthropic's terms, gray-to-hostile elsewhere, brittle. Rejected;
   Rafu holds no inference credentials at all.
3. **MCP-based integration** — MCP standardizes tool access, not "run a full
   agentic task on vendor X's subscription"; does not exist as a cross-vendor
   execution surface. Rejected for this purpose.
4. **Orchestrate the official, user-installed CLIs as child processes with
   delegated auth, file-based handoffs, and Rafu-owned worktrees** — chosen.

## Decision

- Rafu gains a **Conductor**: it runs *roles* (agent definitions) and
  *workflows* (ordered role pipelines with user gates) by spawning external,
  user-installed agent CLIs as child processes. Rafu itself embeds no agent,
  no model client, and no extension host. Nothing executes without a visible,
  user-initiated run.
- **Auth is fully delegated.** Rafu never stores, reads, copies, or proxies
  any provider credential for inference. Adapter status surfaces "not logged
  in — run `codex login` in a terminal"; login happens in the vendor's CLI.
  This is a harder line than usage metering (ADR 0017) because inference acts
  on the user's behalf.
- **Adapters are Rafu-shipped and registry-driven** (mirroring the usage
  provider registry): binary discovery, version probe, headless invocation
  mapping, autonomy-flag mapping, auth-status probe, and **model selection**
  (curated defaults + dynamic listing where the CLI supports it + free-text
  override). Initial roster: Claude Code, Codex, OpenCode, Cline, Kimi CLI,
  Gemini CLI, Cursor CLI. Adapters spawn executable + argument arrays only
  (standing invariant), with a minimal explicit environment.
- **Configuration is plain files, GUI second.** Roles live in
  `.rafu/agents/*.md` (frontmatter: provider, model, autonomy, handoff
  artifact; body: prompt). Workflows live in `.rafu/workflows/*.md`. Files
  are the source of truth — committable, diffable, shareable, usable without
  Rafu; the GUI edits them, never a parallel database. This ADR establishes
  the in-repo `.rafu/` directory as public contract (agents, workflows, runs).
- **Handoffs are files, not stream parsing.** Each role must write its
  artifact to a Rafu-provided handoff directory; step completion = artifact
  present + clean process exit. Captured CLI output is evidence, not
  protocol — adapters stay small and survive vendor flag churn.
- **Runs are repo data, not app state.** Each run persists under
  `.rafu/runs/<id>/` (manifest, per-step artifacts, patches, captured logs),
  gitignored by default with a user choice to commit. Window restoration
  (UserDefaults) is untouched; live role terminals are never restored,
  consistent with ADR 0004/0014.
- **Rafu creates worktrees; models never do.** A mutating role runs in a
  Rafu-created worktree (`rafu/run-<id>`) via the existing `GitService`
  worktree path; read-only roles run against the checkout under the
  adapter's read-only sandbox mapping. Autonomy inside the worktree is
  allowed precisely because the blast radius is bounded.
- **Merge-back is always a user gate.** Rafu presents the worktree diff in
  the existing editor-hosted diff canvas; applying, committing, or discarding
  is explicit user action. No automatic commit, no silent overwrite —
  unchanged invariants.
- Live role output renders as terminal tabs (editor-tab peers) under a PTY,
  inheriting the attention/notification pipeline; run structure renders as a
  `.runs` navigator panel plus an editor-hosted run-detail canvas (ADR
  0002/0003 pattern).

## Consequences

- AGENTS.md's non-goal sentence is narrowed the same way ADR 0004 (terminal)
  and ADR 0005 (LSP) narrowed theirs: Rafu *orchestrates* external agent
  CLIs; an *embedded* coding agent, extension host, and marketplace remain
  excluded.
- Execution is planned in [`docs/plans/phases/conductor/`](../plans/phases/conductor/)
  (C0 shim, single-role runs, adapter waves, pipelines, workflow library,
  polish).
- New security-review surface: child agent processes receive repo content and
  act with write access inside worktrees. Rules: argv arrays only; minimal
  env; prompts/artifacts/logs may contain repo text so they stay on disk in
  the repo and are **never** written to Rafu's own logs; child pids register
  with `ProcessResourceRegistry`; worktree removal never uses `--force`;
  merge-back reviews the diff, not the agent's self-report.
- Memory/process accounting: agent CLIs are attributed, user-visible child
  processes (Resources surface), never hidden in Rafu's own number. Rafu's
  idle budget is unaffected when no run is active.
- Ongoing maintenance: vendor CLIs churn flags monthly. Adapters therefore
  keep verified invocation shapes in reference notes with probe procedures,
  and degrade to "adapter needs update" rather than misbehaving.
- Usage metering (ADR 0017) and the Conductor stay separate trust domains:
  metering may read local usage files/cookies read-only; the Conductor holds
  nothing and delegates everything.

**Revisit triggers:** a vendor removing or licensing-away headless CLI mode
revisits that adapter, not the architecture; demand for parallel multi-role
execution graphs (beyond sequential pipelines with gates) is a scope decision
for the workflow-library phase; anything resembling Rafu-native inference or
credential handling requires a new ADR.

**Related:** ADR 0004, 0014, 0016 (terminal + attention), ADR 0017 (usage
trust split), ADR 0002/0003 (navigator + editor-hosted details);
[`docs/plans/phases/conductor/README.md`](../plans/phases/conductor/README.md);
`Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`,
`Sources/RafuApp/Services/GitService.swift` (worktrees),
`Sources/RafuApp/Usage/UsageProviderRegistry.swift` (registry pattern).
