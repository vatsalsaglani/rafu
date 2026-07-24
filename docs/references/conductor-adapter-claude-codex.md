# Ensemble Claude Code and Codex adapters

- Applies to: `ClaudeCodeAdapter`, `CodexAdapter`, their shared bounded
  metadata-probe support, and C1 code that probes and invokes these adapters
- Last verified: Claude Code 2.1.218, codex-cli 0.146.0-alpha.3, Swift 6.2.4,
  Xcode 26.3, macOS 26.5.2 (arm64), 2026-07-24

## Verified invocation rules

Both adapters accept a prompt as one argument, not shell text. An empty model
selection omits the model flag; a curated or custom selection is passed
verbatim as the model argument.

Claude Code 2.1.218 accepts this argument-vector shape:

```text
claude -p <prompt> [--model <id>] --output-format stream-json --verbose \
  --no-session-persistence --permission-mode <mode>
```

Autonomy maps as follows:

| Rafu autonomy | Claude Code permission mode |
|---|---|
| `readOnly` | `plan` |
| `worktreeWrite` | `bypassPermissions` |

`bypassPermissions` is the installed CLI's explicit unattended permission
mode. It is a vendor-level permission bypass, not an operating-system sandbox.
Rafu restricts its use to the Ensemble-created worktree for
`worktreeWrite`. The adapter does not also pass a separate
dangerous-skip-permissions flag.

Codex 0.146.0-alpha.3 accepts this argument-vector shape:

```text
codex --ask-for-approval never exec [--model <id>] \
  --sandbox <read-only|workspace-write> --cd <working-directory> \
  --json --ephemeral <prompt>
```

`--ask-for-approval` is a global option and must precede `exec`. Placing it
after `exec` exits with status 2 in this build. `readOnly` maps to the
`read-only` sandbox and `worktreeWrite` maps to `workspace-write`;
`danger-full-access` is never selected.

## Executable discovery and child environment

The verified installed binaries are:

| CLI | Absolute executable | Version | Install observation |
|---|---|---|---|
| Claude Code | `/Users/vatsalsaglani/.local/bin/claude` | `2.1.218 (Claude Code)` | native arm64 executable reached through a symlinked install |
| Codex | `/Applications/ChatGPT.app/Contents/Resources/codex` | `codex-cli 0.146.0-alpha.3` | native arm64 executable bundled with ChatGPT |

Discovery runs `/usr/bin/which` with `["claude"]` or `["codex"]`, never a
shell command, then checks known absolute fallback locations. Only one
absolute executable path is accepted. The discovered executable is cached on
the adapter instance, and its parent directory is prepended to the fixed C0
child `PATH` so version-manager and symlinked installs can resolve their own
siblings.

The version and auth probes receive only `PATH`, `HOME`, `USER`, and
`LOGNAME`. They do not inherit inference-token variables. Claude's real
signed-in status probe returned unauthenticated when `USER` was omitted;
including `USER` (and matching `LOGNAME`) restored the correct signed-in
result. C1 must call `probe()` and `invocation(...)` on the same adapter
instance so invocation sees the verified executable cache. An invocation
without a prior successful probe fails closed through the C0 placeholder.

## Authentication and model choices

Claude authentication is classified from the exit status of:

```text
claude auth status --json
```

Codex authentication is classified from the exit status of:

```text
codex login status
```

For both commands, status 0 means authenticated, status 1 means not
authenticated, and every other launch/timeout/status result is unknown. Auth
stdout and stderr are sent directly to the null device. Rafu does not read a
Claude credential store or `~/.codex/auth.json`; no credential file contents
were read during verification.

Neither installed CLI exposes a verified model-list command, so both adapters
advertise a static curated list plus the existing custom-model entry:

- Claude Code: `fable`, `opus`, `sonnet`, `haiku`. The installed CLI uniquely
  advertises `fable`; the other current aliases agree with
  [Anthropic's model configuration documentation](https://code.claude.com/docs/en/model-config).
- Codex: `gpt-5.6`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, verified
  against the current [Codex model manual](https://learn.chatgpt.com/docs/models.md)
  and [OpenAI model catalog](https://developers.openai.com/api/docs/models).

Do not probe guessed Claude subcommands as bare positional arguments.
`claude help models` was interpreted as a prompt and accidentally invoked
inference. The installed Codex build rejects both `codex help models` and
`codex help model` with status 2.

## Bounded probe lifecycle

Probe work is explicitly `@concurrent`, keeping process launch and polling
off the main actor under Swift 6.2. Captured version/discovery output is
file-backed and bounded to 256 KiB per stream; auth output is discarded.
Every child has a five-second timeout and is registered with
`ProcessResourceRegistry` for its complete live interval. Cancellation,
timeout, and output overflow use bounded direct-child `SIGTERM`/`SIGKILL`
handling and `waitpid` reaping.

Concurrent probes receive generations; only the newest completed generation
may replace the shared executable cache. Cancellation preserves the last
successful cache instead of turning a transient cancellation into a
not-installed result.

## Why these details matter

The phase plan's command shapes were hypotheses. The installed tools require
additional non-interactive and persistence controls, and Codex requires a
different option position than the hypothesis implied. Preserving these
verified vectors avoids an interactive session, unexpected state reuse,
approval prompts, accidental full-disk autonomy, and false signed-out status.
Bounded, registered subprocesses keep the Settings probe safe and observable
without exposing identity or credential-shaped output.

## Reproduction and evidence

These metadata-only commands reproduce the verified CLI surface:

```sh
/usr/bin/which claude
file /Users/vatsalsaglani/.local/bin/claude
claude --version
claude --help
claude auth --help
claude auth status --json >/dev/null

/usr/bin/which codex
file /Applications/ChatGPT.app/Contents/Resources/codex
codex --version
codex --help
codex exec --help
codex login --help
codex login status >/dev/null
codex --ask-for-approval never exec --help
```

The negative Codex placement check is:

```sh
codex exec --ask-for-approval never --help
```

It must exit 2 for this verified build. Do not use `claude help models` as a
negative probe because unknown positional input can run as an inference
prompt.

The C2 implementation added 18 tests over the C0 baseline: 1,362 became
1,380 tests in 60 suites. The focused adapter selection ran 37 tests in both
parallel and nonparallel modes. Final headless evidence:

```sh
swift build
swift test --filter Adapter
swift test --no-parallel --filter Adapter
swift test
swift test --no-parallel
./script/format.sh --fix
./script/format.sh --lint
git diff --check
```

Both builds completed with zero warnings; both full-suite modes passed all
1,380 tests. This phase was explicitly headless-only, so no GUI pass was run.

## Deviations from the phase hypotheses

- Claude's `stream-json` output needs `--verbose`; the verified invocation
  also disables session persistence and uses explicit `plan` or
  `bypassPermissions` modes.
- Claude uses no separate dangerous-skip flag.
- Codex's approval policy is global and precedes `exec`; the verified exec
  invocation also selects the sandbox and enables JSON and ephemeral modes.
- Neither CLI has a verified model-list command, so discovery remains static
  curated choices plus a custom entry.

## Remaining risks

- Claude `bypassPermissions` remains powerful inside the worktree even though
  it does not remove the operating-system boundary.
- C1 integration can fail closed if it constructs a new adapter between probe
  and invocation.
- Direct-child signal handling does not clean up unexpected grandchildren.
- A child can overshoot the 256 KiB file cap during the 20 ms polling
  interval, although the retained/read output remains bounded.
- Static model lists can drift as vendors revise their catalogs.

## Related code, ADRs, and phases

- `Sources/RafuApp/Conductor/Adapters/ClaudeCodeAdapter.swift`
- `Sources/RafuApp/Conductor/Adapters/CodexAdapter.swift`
- `Tests/RafuAppTests/Conductor/ClaudeCodeAdapterTests.swift`
- `Tests/RafuAppTests/Conductor/CodexAdapterTests.swift`
- `docs/decisions/0018-conductor-external-agent-orchestration.md`
- `docs/plans/phases/conductor/README.md`
- `docs/plans/phases/conductor/C0-shim.md`
- `docs/plans/phases/conductor/C1-single-role-runs.md`
- `docs/plans/phases/conductor/C2-adapters-claude-codex.md`
- `docs/references/conductor-pty-spawn-and-child-environment.md`

The intended `docs/references/README.md` index row, to be added by the shared
index owner, is:

```markdown
| [`conductor-adapter-claude-codex.md`](conductor-adapter-claude-codex.md) | Changing Claude Code or Codex Ensemble discovery, auth probes, model choices, autonomy mapping, invocation argv, or bounded probe lifecycle |
```
