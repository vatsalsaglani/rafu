# Launcher CLI grammar and validation

- **Applies to:** `rafu` arguments, request drafts, help/version behavior, and local IPC handoff
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-26

## Rule or observed behavior

Parse and validate the entire invocation before launching the app or touching an IPC socket. An option that requires a value must not consume the next option token as that value. Empty or `-`-prefixed values following `--ssh` and `--goto` are usage errors; a future grammar that needs a literal dash-prefixed path must add an explicit `--` delimiter deliberately.

Keep these result classes distinct:

- Help/version succeed without app IPC.
- Invalid grammar exits with `EX_USAGE` (64).
- A valid request whose transport is unavailable exits with `EX_UNAVAILABLE` (69) during bootstrap.
- Product Phase 0 replaces the valid-but-unavailable branch with versioned IPC acknowledgement.

Local folder and goto requests use the versioned same-user Unix-domain socket
described in [`cli-app-ipc.md`](cli-app-ipc.md) and ADR 0009. Paths are resolved
and validated in the caller before any socket or app-launch side effect. If no
listener exists, the CLI locates its enclosing `Rafu.app` (real executable
path, not `argv[0]`; symlink install), invokes `open -a <bundle>` without a
document, and retries IPC for under ten seconds. Only total IPC failure uses
the legacy `open -a <bundle> <folder>` document-open path.

`--new-window`, `--reuse-window`, and `--goto` are honored by the app router.
`--wait` is accepted but deferred: after an acknowledgement with
`waitSupported: false`, the CLI prints one line explaining that the request was
opened without waiting and exits successfully. `--status`, SSH routing, and
SSH host listing remain valid-but-unavailable surfaces.

`ensemble` is the one reserved first positional subcommand and is recognized
before the launcher parser:

```text
rafu ensemble status [<run>...] [--tree] [--since <cursor>] [--json]
rafu ensemble artifact <run> <step> [--json]
rafu ensemble await <run>... --state <state> [--any] [--timeout <sec>] [--json]
rafu ensemble --help | help
```

The reservation is deliberately strict. If a filesystem entry named
`./ensemble` exists, bare `rafu ensemble ...` exits 64 and tells the user to
spell the workspace path as `rafu ./ensemble`; the CLI never guesses whether
the bare word meant a path or the subcommand. With no local collision, it is
always the subcommand. A dot-prefixed or otherwise explicit path still falls
through to the existing workspace launcher.

Every Ensemble invocation is parsed completely before a socket is opened.
Repeated singleton flags, unknown verbs/options/states, missing operands,
negative step indexes, nonpositive/nonfinite timeouts, and an option in place
of another option's value all exit 64. `--state` may repeat to express a set.
The read-only surface never launches the app, starts a run, writes repository
state, or merges.

Ensemble uses a typed sysexits-style set: 0 success, 64 invalid usage, 65
missing/invalid run data, 69 app/workspace/heartbeat unavailable, 75 user
timeout or temporary failure, and 77 denied permission. Full wire and verb
shapes are recorded in [`ensemble-ipc-verbs.md`](ensemble-ipc-verbs.md).

## Why it matters

Misclassifying `rafu --ssh --wait` as host alias `--wait` makes invalid input look like a transport failure and can later route a request to the wrong workspace. Side effects must begin only after grammar and path/location validation succeeds.

## Reproduction or evidence

The initial review found that `--ssh` and `--goto` advanced to the next array element without checking whether it was another option. Regression tests now cover both cases.

`EnsembleArgumentParserTests` covers every verb and flag, value-consumes-option
guards, duplicate flags, unknown states/verbs, and the collision matrix.
`EnsembleClientStreamTests` proves the read-only runner maps socket, remote,
heartbeat, and user-timeout outcomes to the typed exit codes without launching
the app.

## Verification

```bash
swift test --filter LauncherArgumentParserTests
swift test --filter EnsembleArgumentParserTests
swift test --filter EnsembleClientStreamTests
swift run rafu --help
swift run rafu --ssh --wait
```

The final command must exit 64 and report a missing `--ssh` value.

## Related code, ADRs, and phases

- `Sources/RafuCore/Launcher/LauncherArgumentParser.swift`
- `Sources/RafuCore/Launcher/IPC/LauncherIPCClient.swift`
- `Sources/RafuCore/Ensemble/EnsembleArgumentParser.swift`
- `Sources/RafuCore/Ensemble/EnsembleCommandRunner.swift`
- `Sources/RafuCore/Ensemble/EnsembleExitCode.swift`
- `Sources/RafuCLI/main.swift`
- `Tests/RafuCoreTests/LauncherArgumentParserTests.swift`
- `Tests/RafuCoreTests/LauncherIPCClientTests.swift`
- `Tests/RafuCoreTests/EnsembleArgumentParserTests.swift`
- `Tests/RafuCoreTests/EnsembleClientStreamTests.swift`
- [`cli-app-ipc.md`](cli-app-ipc.md)
- [`ensemble-ipc-verbs.md`](ensemble-ipc-verbs.md)
- [ADR 0009](../decisions/0009-local-cli-app-ipc.md)
- [Phase 0](../plans/phases/phase-0-feasibility.md)
- [Phase 1C](../plans/phases/phase-1c-cli-integration.md)
