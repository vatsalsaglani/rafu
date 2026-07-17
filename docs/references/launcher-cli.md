# Launcher CLI grammar and validation

- **Applies to:** `rafu` arguments, request drafts, help/version behavior, and local IPC handoff
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-18

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

## Why it matters

Misclassifying `rafu --ssh --wait` as host alias `--wait` makes invalid input look like a transport failure and can later route a request to the wrong workspace. Side effects must begin only after grammar and path/location validation succeeds.

## Reproduction or evidence

The initial review found that `--ssh` and `--goto` advanced to the next array element without checking whether it was another option. Regression tests now cover both cases.

## Verification

```bash
swift test --filter LauncherArgumentParserTests
swift run rafu --help
swift run rafu --ssh --wait
```

The final command must exit 64 and report a missing `--ssh` value.

## Related code, ADRs, and phases

- `Sources/RafuCore/Launcher/LauncherArgumentParser.swift`
- `Sources/RafuCore/Launcher/IPC/LauncherIPCClient.swift`
- `Sources/RafuCLI/main.swift`
- `Tests/RafuCoreTests/LauncherArgumentParserTests.swift`
- `Tests/RafuCoreTests/LauncherIPCClientTests.swift`
- [`cli-app-ipc.md`](cli-app-ipc.md)
- [ADR 0009](../decisions/0009-local-cli-app-ipc.md)
- [Phase 0](../plans/phases/phase-0-feasibility.md)
- [Phase 1C](../plans/phases/phase-1c-cli-integration.md)
