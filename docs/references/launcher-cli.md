# Launcher CLI grammar and validation

- **Applies to:** `rafu` arguments, request drafts, help/version behavior, and future IPC handoff
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-12

## Rule or observed behavior

Parse and validate the entire invocation before launching the app or touching an IPC socket. An option that requires a value must not consume the next option token as that value. Empty or `-`-prefixed values following `--ssh` and `--goto` are usage errors; a future grammar that needs a literal dash-prefixed path must add an explicit `--` delimiter deliberately.

Keep these result classes distinct:

- Help/version succeed without app IPC.
- Invalid grammar exits with `EX_USAGE` (64).
- A valid request whose transport is unavailable exits with `EX_UNAVAILABLE` (69) during bootstrap.
- Product Phase 0 replaces the valid-but-unavailable branch with versioned IPC acknowledgement.

Local folder opening (`rafu <path>`) is now implemented without IPC: the CLI
locates its enclosing `Rafu.app` and runs `open -a <bundle> <folder>`. How it
finds the bundle (real executable path, not `argv[0]`; symlink install) is its
own concern — see [`cli-app-location.md`](cli-app-location.md) and
[ADR 0007](../decisions/0007-cli-app-location-symlink.md). Richer request
handoff (`--goto`, `--new-window` against an already-running window) remains the
future IPC work above.

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
- `Tests/RafuCoreTests/LauncherArgumentParserTests.swift`
- [Phase 0](../plans/phases/phase-0-feasibility.md)
- [Phase 1C](../plans/phases/phase-1c-cli-integration.md)
