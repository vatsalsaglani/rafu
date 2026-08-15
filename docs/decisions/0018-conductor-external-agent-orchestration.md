# ADR 0018: The Ensemble — orchestrate external agent CLIs, embed none

- **Status:** Accepted (narrows the "embedded coding agent" initial non-goal)
- **Date:** 2026-07-24 (renamed 2026-07-25; see Naming)

## Naming

This feature was designed and first implemented as "the Conductor". On
2026-07-25 the user renamed it **Ensemble**: [conductor.build](https://www.conductor.build)
is an established Mac product in this exact category (parallel Claude
Code/Codex/Cursor agents in isolated workspaces with review-and-merge), so
keeping the name would read as derivative. The rename is deliberately
**product-surface only**:

- All user-visible strings and all documentation prose say **Ensemble**.
- Internal Swift symbols keep the `Conductor*` prefix, and the phase docs
  keep the `docs/plans/phases/conductor/` folder, `conductor/*` branch
  names, and `conductor-*` reference-note filenames. These are pre-rename
  history, never shipped to users, and renaming them mid-fan-out would
  churn every phase contract for zero user value.
- New user-facing strings must say Ensemble; new internal symbols continue
  the `Conductor*` prefix for consistency with the existing family.
- "Conductor" still appears, correctly, where docs refer to the third-party
  conductor.build product itself (e.g. as a design reference in ADR 0012 and
  the flat-UI refresh plan).

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
usage metering (ADR 0017), and the notch companion. The Ensemble is a thin
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

- Rafu gains an **Ensemble**: it runs *roles* (agent definitions) and
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
  gitignored by default with a user choice to commit. At this decision’s
  original scope, window restoration (UserDefaults) was untouched. ADR 0023
  now permits inert Terminal Group metadata, but live role terminals are never
  restored and no run data or Ensemble capability enters that schema.
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
- Usage metering (ADR 0017) and the Ensemble stay separate trust domains:
  metering may read local usage files/cookies read-only; the Ensemble holds
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

## Amendment (2026-07-26): coordinator verbs, capability token, streaming

This amendment admits an external, user-installed coordinator CLI without
weakening the original decision that Rafu embeds no agent, holds no inference
credentials, and leaves merge-back behind an explicit human gate.

- **Coordinator model: hub-and-spoke.** The user launches the coordinator in
  a visible terminal tab, and it may drive the Ensemble through
  `rafu ensemble <verb>` over the ADR 0009 socket. Only the coordinator
  spawns child runs. Children may propose successors through a `proposes:`
  artifact block, but they never spawn. Nested coordinators are structurally
  impossible in v1 because only coordinator sessions receive the capability
  token.
- **Verb surface and trust classes.** The read-only `status`, `artifact`, and
  `await` verbs require no token. `run`, `abort`, `note`, `grant` (which reads
  the caller's own grant), and `propose-merge` require the coordinator token.
  `propose-merge` only queues a diff at the human gate and **never merges**;
  it exposes this ADR's gated merge-back as an API. The CLI reuses
  `sysexits`: 0 for success, 64 `EX_USAGE`, 65 `EX_DATAERR`, 69
  `EX_UNAVAILABLE`, 75 `EX_TEMPFAIL` (including grant exhaustion or timeout),
  and 77 `EX_NOPERM` (including a missing or dead token).
- **Capability token.** Rafu mints one token per coordinator session, binds it
  to one grant, and injects it as `RAFU_ENSEMBLE_TOKEN` through the existing
  curated-environment overlay documented in
  `conductor-pty-spawn-and-child-environment.md`. The token exists only in
  memory and dies with the app. After an app relaunch, a resumed coordinator
  must be re-granted by the user; token-free read-only verbs remain available
  so it can re-orient. The token is a capability, not a credential: it
  unlocks no provider and no secret. It is never logged, persisted, included
  in captured PTY output, or written to a manifest. Worker children never
  receive it.
- **Grant and exhaustion.** At coordinator launch the user sets the maximum
  concurrent child runs (default 3, min-ed with the window cap), maximum total
  child runs, allowed CLIs/providers, an optional usage ceiling, and an
  optional wall-clock deadline. Usage enforcement is best-effort and follows
  C7's honesty rule when a provider reports no measurement. Exhaustion parks
  the coordinator with exit 75 and asks the user; it never fails silently and
  never continues silently.
- **Streaming, not polling.** `await` and event delivery use a new long-lived
  subscription connection on the existing socket, with one framed JSON event
  per frame, heartbeats, and bounded buffers. One-shot verbs keep the existing
  request/response behavior. This amends ADR 0009's v1 wording from "one frame
  per connection" to **"one frame per connection for request/response kinds;
  subscription kinds hold the connection and stream frames."**
- **CLI grammar and collision handling.** `rafu ensemble` is the first
  reserved subcommand. The collision rule is strict: if a filesystem entry
  named `ensemble` exists in the working directory, the bare invocation is an
  `EX_USAGE` error that names `rafu ./ensemble` as the disambiguation. The CLI
  never guesses.
- **Coordinator placement and attribution.** The coordinator runs
  interactively in the user's checkout, with no coordinator worktree and no
  coordinator manifest in v1. Durable attribution lives in each child's
  manifest through `startedBy`. This does not weaken "Rafu creates worktrees;
  models never do": every child still receives a Rafu-created worktree.
- **Naming exception.** RafuApp internals continue to use the `Conductor*`
  prefix, including `ConductorEnsemble*` for new coordinator types. RafuCore
  types that encode the user-visible CLI namespace use the `Ensemble*` prefix.
  This is a deliberate exception to the "new internal symbols continue the
  `Conductor*` prefix" rule, scoped to `Sources/RafuCore/Ensemble/`; user-visible
  strings and documentation prose continue to say Ensemble.

**Revisit triggers:** mesh admission in which children may spawn; nested
coordinators; token persistence across app relaunch; or distribution of any
coordinator skill through a marketplace. Each requires revisiting this
amendment.

## Amendment (2026-08-16): Terminal Group restoration and capacity

ADR 0023 changes the terminal presentation and restoration schema, not the
Ensemble trust boundary. Workspace restoration may now contain inert Terminal
Group metadata. It does not restore a live role session, its PTY, captured
output, environment, token, grant, manifest, launch descriptor, or Ensemble
capability. An Ensemble pane can restore only as the fixed unavailable
placeholder defined by ADR 0023.

The per-window six-live-session limit includes ordinary shells, Agent
Terminals, Ensemble coordinator terminals, and Ensemble role terminals.
This is a shared capacity limit, not a capability grant. The delegated-auth,
file-handoff, Rafu-created-worktree, and explicit merge-back rules in this ADR
are unchanged.
