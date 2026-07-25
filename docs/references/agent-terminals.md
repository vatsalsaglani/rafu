# Agent Terminal launch contract

## Applies to

This note applies to the interactive Agent Terminal entry points introduced by
AT-01: the Terminals panel menu, New Agent Terminal sheet, app menu, command
palette, terminal-session identity, and Resources attribution. It does not
apply to Ensemble runs or adapter invocations used by the run engine.

## Last verified

- 2026-07-26
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`)
- macOS 26.5.2 (25F84), arm64
- Installed CLI versions are recorded in the probe table below.

## Rule

An Agent Terminal is the user's interactive vendor-CLI session, not an
Ensemble run:

- Spawn an absolute executable with an argument array; never use a shell
  command string.
- Give the child exactly one environment key, `PATH`.
- Start with `RafuConductorEnvironment.curatedPath`. Prepend the parent of the
  adapter-probed executable only when that directory is not already a complete
  PATH component.
- Never add `RAFU_HANDOFF`, `RAFU_RUN_DIR`, `RAFU_ENSEMBLE_TOKEN`, inherited
  credentials, or any other `RAFU_*` key.
- Never attach an output log. The session is interactive user activity, not
  reproducible run evidence.
- Emit a model flag only when the installed CLI's `--help` output verified the
  flag. A hypothesis launches bare and carries a visible verification note.
- Missing and known-unauthenticated CLIs remain visible but disabled with a
  textual reason. An adapter that reports auth as unknown remains launchable
  and lets its own CLI make the authoritative decision.
- The starting directory must resolve to the workspace root or a descendant.
  Resolving symlinks before the containment check prevents a link inside the
  workspace from escaping it.

The launch roster comes from `ConductorAdapterRegistry.all`; a second Agent
Terminal-specific discovery authority would drift from Settings and Ensemble.

## Interactive launch probe table

Each verified row below was checked from the named installed executable using
`--help` on 2026-07-26. “Bare” means no prompt or non-interactive command is
added; the process owns the existing SwiftTerm PTY.

| CLI | Installed version | Interactive argv after the executable | Model argv | Status and evidence |
|---|---:|---|---|---|
| Claude Code (`claude`) | 2.1.220 | `[]` | `["--model", "<model>"]` | **Verified** — help describes interactive use by default and `--model <model>`. |
| Codex (`codex`) | 0.145.0 | `[]` | `["--model", "<model>"]` | **Verified** — no subcommand opens the interactive UI; help lists `-m, --model <MODEL>`. |
| OpenCode (`opencode`) | 1.18.4 | `[]` | `["--model", "<model>"]` | **Verified** — `opencode [project]` starts the TUI in the current directory; help lists `-m, --model`. |
| Cline (`cline`) | 3.0.46 | `["--tui"]` | `["--model", "<model>"]` | **Verified** — help requires `-i, --tui` for the interactive TUI and lists `-m, --model <model-id>`. |
| Kimi CLI (`kimi`) | not installed | `[]` | omitted | **Hypothesis** — bare launch only. Run `kimi --help` after installing it before adding any model flag. |
| Gemini CLI (`gemini`) | 0.52.0 | `[]` | `["--model", "<model>"]` | **Verified** — bare invocation is interactive and help lists `-m, --model`. |
| Cursor CLI (`cursor-agent`) | 2025.09.18-7ae6800 | `[]` | `["--model", "<model>"]` | **Verified** — bare invocation starts the agent and help lists `--model <model>`. |

Probe commands:

```bash
claude --help
codex --help
opencode --help
cline --help
kimi --help
gemini --help
cursor-agent --help
```

The Kimi executable was absent from the adapter's launchd-safe search path as
well as the interactive shell path. Its row is intentionally not inferred from
another product, documentation snippet, or a similarly named binary.

## Identity and lifecycle

`TerminalProcessSpec.agentProvider` carries vendor identity into the existing
terminal controller. The editor tab shows the CLI name; the Terminals panel
and Control-Tab switcher add the provider mark beside that same text.
Resources registers the child as `.agentTerminal`, displayed as **Agent
Terminal**, while Ensemble `.agent` children remain **Ensemble Agent** and
login shells remain **Terminal**.

Agent Terminals use the normal terminal exit, attention, parking, and close
pipeline. Like all terminal editor resources under ADR 0014, they are
ephemeral and never restored after relaunch. No output capture is added:
capturing an interactive conversation would turn user terminal activity into
silent durable evidence and would falsely imply Ensemble run semantics.

## Why it matters

The one-action launch is useful only if it does not quietly become an
authorization boundary. Exact environment and verified-argv rules keep the
session equivalent to the vendor CLI the user chose to run, while distinct
identity prevents Resources and navigation surfaces from claiming it is an
Ensemble agent.

## Reproduction and verification

```bash
swift test --filter AgentTerminal
swift test --filter 'TerminalsPanel|EditorTabSwitcher|ProcessAttribution'
swift test --no-parallel
```

The focused tests prove the gating matrix, PATH-only environment, absence of
Ensemble keys and output capture, adapter-directory prepend rule, verified-only
model flags, workspace containment, session reveal, provider identity, and
resource labels.

## Related

- [ADR 0004](../decisions/0004-embedded-terminal.md)
- [ADR 0014](../decisions/0014-terminal-as-editor-tab.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)
- [ADR 0021](../decisions/0021-agent-terminals.md)
- [AT-01 phase](../plans/phases/conductor/AT-01-agent-terminal-sessions.md)
- [PTY spawn and child environment](conductor-pty-spawn-and-child-environment.md)
- [Agent icon assets](agent-icon-assets.md)
