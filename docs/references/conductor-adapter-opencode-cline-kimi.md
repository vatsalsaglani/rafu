# Ensemble adapters: OpenCode, Cline, and Kimi CLI

## Applies to

Use this note when implementing, reviewing, or re-verifying Rafu's Ensemble
adapters for OpenCode, Cline, or Kimi CLI. It records the locally observed CLI
surfaces, the upstream-only Kimi invocation, the autonomy guarantees Rafu may
honestly claim, and the bounded metadata-probe contract.

Last verified on:

- macOS 26.5.2 (25F84), arm64
- Apple Swift 6.2.4
- OpenCode 1.18.4
- Cline 3.0.46
- Kimi CLI not installed; its invocation remains unverified locally

No live agent task or inference request was launched while gathering this
evidence. No credential file contents were read. The only auth probe that ran
was OpenCode's metadata-only `auth list`.

## Status summary

| CLI | Local status | Headless/autonomy support | Auth status | Models |
|---|---|---|---|---|
| OpenCode 1.18.4 | Verified installed | `worktreeWrite` verified; `readOnly` unsupported | Metadata-only classification verified | Dynamic discovery verified, with bounded parsing and curated fallback |
| Cline 3.0.46 | Verified installed | `readOnly` and `worktreeWrite` verified from installed help | Unknown; no safe status command found | Curated routes plus free text; no safe dynamic listing found |
| Kimi CLI | Absent, invocation unverified | Documented `worktreeWrite` shape only; `readOnly` unsupported | Unknown | Curated choices plus free text; no discovery |

An installed binary is not by itself a supported adapter. Each probe also
checks the required headless flags. If a vendor changes those flags, the
adapter reports an update/no-headless hint and supports no autonomy level
rather than guessing.

## OpenCode 1.18.4

The executable resolved to
`/Users/vatsalsaglani/.opencode/bin/opencode`, outside the curated Ensemble
`PATH`. The installed help verified the `run` subcommand and its `--format`,
`--dir`, `--model`, and `--auto` options. Rafu constructs this argv:

```text
run --format json --dir <working-directory> [--model <provider/model>] --auto -- <prompt>
```

Each placeholder is one argv element; Rafu never forms a shell command.
`--` prevents a prompt beginning with a hyphen from being parsed as another
option.

Only `worktreeWrite` is supported. OpenCode's named `plan` agent is an agent
configuration, not a verified filesystem sandbox, so it does not satisfy the
Ensemble's read-only guarantee. A read-only invocation therefore fails
closed instead of passing `--agent plan`.

`opencode models --pure` returned 66 model identifiers in 2,320 bytes. Dynamic
model parsing is deliberately strict:

- combined output is capped at 256 KiB by the subprocess runner;
- parsing accepts at most 2,048 rows;
- one model identifier may contain at most 512 ASCII bytes;
- identifiers must have provider/model syntax;
- duplicates are removed while preserving first-seen order; and
- missing, failed, malformed, non-ASCII, oversized, or over-row-cap output
  falls back to the curated model choices.

`opencode auth list --pure` reported one configured credential as metadata.
Rafu classifies only the credential count and never opens OpenCode's auth
files. A successful zero-credential result maps to a terminal login hint;
launch failure, nonzero exit, unexpected output, cancellation, timeout, or
oversized output maps to unknown.

Exact locally executed probes:

```sh
/usr/bin/which -a opencode
/Users/vatsalsaglani/.opencode/bin/opencode --version
/Users/vatsalsaglani/.opencode/bin/opencode run --help --pure
/Users/vatsalsaglani/.opencode/bin/opencode models --pure
/Users/vatsalsaglani/.opencode/bin/opencode auth list --pure
/usr/bin/env -i HOME=/Users/vatsalsaglani PATH=/Users/vatsalsaglani/.opencode/bin:/usr/local/bin:/opt/homebrew/bin:/Users/vatsalsaglani/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C NO_COLOR=1 /Users/vatsalsaglani/.opencode/bin/opencode auth list --pure
```

Re-run those metadata-only commands after upgrading OpenCode. Do not infer
read-only safety from an agent name; re-verification requires an explicit
filesystem access-control guarantee.

## Cline 3.0.46

The executable resolved to
`/Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/cline`. This is an NVM
installation, so its directory must be prepended to the curated child `PATH`
for the executable's Node shebang to resolve.

The installed help verified a direct positional headless prompt,
`--plan`, `--json`, `--auto-approve <boolean>`, `--cwd`, and `--model`.
Rafu constructs these argv shapes:

```text
# readOnly
--json --cwd <working-directory> --plan --auto-approve false [--model <id>] -- <prompt>

# worktreeWrite
--json --cwd <working-directory> --auto-approve true [--model <id>] -- <prompt>
```

Both autonomy mappings are supported for the verified version. Rafu never
passes Cline's `--worktree`, because C1 already owns the gated worktree
lifecycle. It never launches or automates `--tui`.

Cline routes model providers itself. Rafu exposes curated major routes and a
free-text override, but reports no dynamic model discovery because no safe
listing command was found. Auth status remains unknown: `cline auth` is a
configuration surface, while `cline config` can display credential material
and was deliberately not executed.

Exact locally executed probes:

```sh
/usr/bin/which -a cline
/Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/cline --version
/Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/cline --help
/Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/cline auth --help
/Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/cline config --help
/usr/bin/env -i HOME=/Users/vatsalsaglani PATH=/Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin:/usr/local/bin:/opt/homebrew/bin:/Users/vatsalsaglani/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C NO_COLOR=1 /Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/cline --version
```

Re-run those help/version probes after upgrading Cline. Do not run `cline
config` as an auth-status probe, and do not automate its interactive TUI.

## Kimi CLI: documented, not locally verified

`/usr/bin/which -a kimi` exited 1 and the adapter's audited candidate paths
were absent. No local Kimi version, help, headless mode, auth, or model-list
claim is therefore verified.

The implemented worktree-write shape follows Moonshot's current print-mode
documentation:

```text
kimi --print -p <prompt> --output-format=stream-json [--model <id>]
```

The upstream docs describe print/prompt mode as automatically granting tool
permissions and as incompatible with plan mode. Rafu therefore documents only
`worktreeWrite`; `readOnly` fails closed. It adds no speculative plan,
auto-approval, or yolo flag and never automates a TUI. Kimi auth remains
unknown and model discovery is unavailable.

Upstream evidence:

- [Print mode](https://moonshotai.github.io/kimi-cli/en/customization/print-mode.html)
- [Kimi CLI changelog](https://moonshotai.github.io/kimi-cli/en/release-notes/changelog.html)
- [Kimi command reference](https://moonshotai.github.io/kimi-code/en/reference/kimi-command.html)

The only locally executed Kimi probe was:

```sh
/usr/bin/which -a kimi
```

After installing or upgrading Kimi, the user should run:

```sh
/usr/bin/which -a kimi
kimi --version
kimi --help
```

These are re-verification commands, not evidence that a local Kimi executable
was present during C3. Inspect the output for non-interactive print/prompt,
model, and streaming output flags before treating the documented argv as
verified. Do not launch a real task or interactive TUI merely to classify the
adapter.

## Shared bounded-probe and invocation rules

Metadata probes use an absolute executable plus an argument array, null
standard input, and a minimal explicit environment:

- `HOME`
- curated `PATH`, with the resolved executable directory prepended exactly
  once when it is outside that path
- `LC_ALL=C`
- `NO_COLOR=1`

They never inherit inference credential variables. The general version/help
timeout is 5 seconds; model discovery gets 10 seconds. Output caps are 32 KiB
for version, 64 KiB for help/auth metadata, and 256 KiB for models. Output is
captured to a per-probe temporary directory, read only within the cap, and
removed after classification. Cancellation, timeout, or excessive output
stops the child with `SIGTERM`, escalates to `SIGKILL` after a bounded grace
period, and reports failure. Probe PIDs register with
`ProcessResourceRegistry` for the lifetime of the child.

Real role prompts never enter the metadata runner. An adapter builds the
prompt as an argv element and C1 launches it through the terminal process
seam. Its environment contains only the C0 handoff/run-directory keys and
curated `PATH`, adjusted for an installation outside that path. Prompt and
repository text are not logged by these adapters.

Two C0 contract limits require explicit fail-closed behavior:

1. `ConductorCLIAdapter` has no per-autonomy support or typed unsupported
   result. C3 retains verified capabilities internally and returns
   `/usr/bin/false` with no prompt argv for an unsupported autonomy.
2. `AdapterInvocation` has no current-working-directory field. OpenCode and
   Cline pass their verified cwd flags; Kimi relies on C1's process seam to
   set the working directory.

These are compatibility boundaries, not evidence that an unsupported mode
works. A Settings-level per-autonomy explanation requires a future
integration-owned contract change.

## Failure modes and verification

- Missing executable: report not installed and build no real invocation.
- Installed but required headless flags missing: retain the absolute path for
  diagnostics, report an adapter-update/no-headless hint, and support no
  autonomy level.
- Unsupported autonomy: execute `/usr/bin/false` without forwarding the
  prompt.
- Metadata probe launch failure, timeout, cancellation, nonzero exit,
  malformed output, or output overflow: degrade to unknown/curated fallback;
  never infer success.
- Vendor flag churn: re-run the exact metadata commands above and update the
  recorded fixtures, adapter, and this note together.
- Executable moved after probing: recreate the adapter (normally by
  restarting Rafu) before probing again, because one adapter instance caches
  its located absolute path and capability classification.

Headless implementation checks:

```sh
swift test --filter 'OpenCodeAdapter|ClineAdapter|KimiAdapter'
swift build
swift test
swift test --no-parallel
./script/format.sh --fix
./script/format.sh --lint
```

Do not run `build_and_run.sh` for this adapter-only phase.

## Related code and decisions

- `Sources/RafuApp/Conductor/Adapters/OpenCodeAdapter.swift`
- `Sources/RafuApp/Conductor/Adapters/ClineAdapter.swift`
- `Sources/RafuApp/Conductor/Adapters/KimiAdapter.swift`
- `Tests/RafuAppTests/Conductor/OpenCodeAdapterTests.swift`
- `Tests/RafuAppTests/Conductor/ClineAdapterTests.swift`
- `Tests/RafuAppTests/Conductor/KimiAdapterTests.swift`
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)
- [Ensemble execution plan](../plans/phases/conductor/README.md)
- [C3 phase](../plans/phases/conductor/C3-adapters-opencode-cline-kimi.md)

## Intended index row (integration-owned; not edited here)

```markdown
| [`conductor-adapter-opencode-cline-kimi.md`](conductor-adapter-opencode-cline-kimi.md) | Implementing or re-verifying OpenCode, Cline, or Kimi Ensemble adapters: CLI versions/argv, autonomy support limits, bounded probes, auth metadata, model discovery parsing/caps, PATH handling, and exact re-probe commands |
```
