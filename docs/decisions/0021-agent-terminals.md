# ADR 0021: Agent terminals — interactive vendor CLIs as first-class terminal sessions

- **Status:** Accepted
- **Date:** 2026-07-26

## Context

ADR 0004 adopted a lazy, bounded embedded terminal whose default process is
the user's login shell. ADR 0018 later allowed Rafu to orchestrate external,
user-installed agent CLIs through the Ensemble while continuing to embed no
agent and hold no inference credentials. Users also need a narrower path:
open an authenticated vendor CLI interactively in the workspace with the same
one-action ergonomics as opening a shell, without creating an Ensemble run.

This path must be visibly agent-aware without accidentally acquiring any
Ensemble capability. In particular, an interactive terminal is the user's own
session. It has no grant, capability token, manifest, run evidence, output
capture, worktree bookkeeping, or graph presence.

## Decision

- Rafu may launch a discovered vendor CLI as an interactive terminal session
  after an explicit user action. This narrows ADR 0004's login-shell default;
  ordinary terminal sessions continue to launch the selected login shell
  unchanged.
- Agent Terminal launches use an absolute executable plus an argument array.
  Rafu never constructs a shell command string.
- The child environment contains exactly `PATH`. Its value is
  `RafuConductorEnvironment.curatedPath`, with the adapter-probed executable's
  parent directory prepended when that directory is outside the curated path.
  Agent Terminals never receive `RAFU_HANDOFF`, `RAFU_RUN_DIR`,
  `RAFU_ENSEMBLE_TOKEN`, provider credentials, or any inherited environment.
- Vendor model arguments are emitted only for CLI shapes verified from the
  installed CLI's help output and recorded in
  `docs/references/agent-terminals.md`. An unverified CLI launches bare and
  the UI states why the requested model was omitted; Rafu never guesses a
  vendor flag.
- Auth remains fully delegated to the vendor CLI. The adapter registry is the
  launch roster; missing and known-unauthenticated CLIs stay visible but
  disabled with a textual reason. An adapter whose CLI cannot report auth
  non-interactively continues to defer to the CLI at launch, consistent with
  ADR 0018.
- Agent Terminal processes register with `ProcessResourceRegistry` as
  `.agentTerminal`, rendered as **Agent Terminal**. They are distinct from
  Ensemble `.agent` processes, which continue to render as **Ensemble Agent**.
- Agent Terminal sessions are ephemeral terminal resources and are never
  restored after relaunch, preserving ADR 0014. Their normal exit, attention,
  parking, close, and per-window teardown behavior is the existing terminal
  behavior.
- Internal symbols use the `AgentTerminal*` prefix. User-visible strings use
  **Agent Terminal**; this surface is never called Ensemble because it carries
  no Ensemble capability.
- The seven CLI marks are vendored static SVGs from
  `@lobehub/icons-static-svg` version `1.94.0` (MIT, Copyright (c) 2023
  LobeHub), normalized only by removing web-only `style` and embedded
  `<title>` metadata while preserving each mark's geometry and
  `fill="currentColor"`. The pinned integrity, source slugs, committed
  SHA-256 values, and refresh procedure live in
  `docs/references/agent-icon-assets.md`.
- Copyright permission to redistribute the icon files does not decide
  trademark rights. Rafu's use is nominative: each mark identifies its own
  vendor CLI. Marks may be scaled and monochrome-tinted as template images,
  but are not redrawn, restyled, used as Rafu branding, or presented as an
  endorsement or partnership. A catalog-level system-symbol fallback is the
  honest degradation path if an asset is unavailable or a vendor objects.

## Consequences

- A user can launch the CLI they already installed and authenticated without
  first opening a shell and typing its command.
- Agent identity follows the live terminal session through terminal chrome
  and Resources while text labels remain present for accessibility.
- The process boundary is deliberately weaker than an Ensemble run in
  capability and stronger in user control: it is interactive and visible,
  but cannot call token-required Ensemble verbs.
- Future coordination must be chosen at spawn time. Promoting a live,
  tokenless terminal would mutate its fixed environment and is therefore not
  permitted; a later feature may offer an explicit relaunch through the
  coordinator path.

## Alternatives considered

- **Tell users to open a shell and type the CLI name.** Rejected because it
  discards registry gating, model selection, consistent identity, and
  one-action launch.
- **Treat every agent terminal as an Ensemble run.** Rejected because it
  silently grants capabilities and invents run evidence for the user's own
  interactive session.
- **Reuse Ensemble adapter invocations.** Rejected because those invocations
  are headless, carry run directories and handoff capability, and may capture
  output.
- **Use initials or hand-drawn substitute marks.** Rejected because the
  products' real, uniformly sourced marks identify them more honestly.

## Revisit triggers

Revisit this decision before restoring live Agent Terminals, inheriting the
host environment, capturing their output, granting Ensemble capability after
spawn, adding an unverified vendor argument, or changing the icon source or
use beyond nominative identification.

## Related

- [ADR 0004](0004-embedded-terminal.md)
- [ADR 0014](0014-terminal-as-editor-tab.md)
- [ADR 0018](0018-conductor-external-agent-orchestration.md)
- [`AT-01-agent-terminal-sessions.md`](../plans/phases/conductor/AT-01-agent-terminal-sessions.md)
- [`conductor-pty-spawn-and-child-environment.md`](../references/conductor-pty-spawn-and-child-environment.md)
