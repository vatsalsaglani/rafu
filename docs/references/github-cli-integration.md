# GitHub integration via system `gh` CLI

- Applies to: `GitHubCLIService`, `GitHubCLILocator`, `GitHubAccountModel`,
  the status-bar account chip, and `GitHubPublishSheet`
- Last verified: Swift 6.2, macOS 26 SDK, 2026-07-19

## Rule or observed behavior

Rafu's "publish to GitHub" flow shells out to the user's installed GitHub
CLI (`gh`) rather than embedding an OAuth client or a GitHub REST adapter.

- **Locator:** `GitHubCLILocator.locate()` checks
  `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`, `/usr/bin/gh` (in that
  order — both Homebrew prefixes are common paths a minimal inherited
  `$PATH` may not include, e.g. Rafu launched from Finder or a fresh shell
  before `.zprofile` runs), then falls back to scanning `$PATH`.
  `GitHubCLIService(executableURL:)` defaults to this locator; a `nil`
  result makes every call throw `.notInstalled` rather than guessing a
  path.
- **Argv-only, own subprocess runner.** `GitHubCLIService.run(_:at:)` spawns
  `Process` with an executable URL plus an argument array — never a shell
  string — writing stdout/stderr to temp files it deletes afterward, with a
  4 MiB per-stream cap (`.commandFailed` if exceeded) and cooperative
  cancellation (`Task.checkCancellation()` polled every 20ms while the
  process runs; cancellation terminates the process).
- **Deliberate environment-handling deviation.** `GitCommandRunner` (Rafu's
  `/usr/bin/git` runner) also starts from
  `ProcessInfo.processInfo.environment`, but overrides a handful of specific
  variables (`GIT_TERMINAL_PROMPT=0`, `GIT_PAGER=cat`, `GIT_EDITOR=true`,
  `GIT_MERGE_AUTOEDIT=no`, `LC_ALL=C`) to force non-interactive, script-safe
  `git` behavior. `GitHubCLIService` passes the **full, unmodified**
  `ProcessInfo.processInfo.environment` with no overrides at all, because
  `gh` needs `HOME`, `GH_CONFIG_DIR`, `GH_TOKEN`, and similar variables
  exactly as the user's shell set them to find its own auth state. This is a
  one-off, commented exception — do not generalize it to other subprocess
  runners without the same justification.
- **Concrete invocations, both explicit and user-confirmed only:**
  - `gh api user` → `GitHubAccount` (account/whoami), parsed by the pure,
    unit-testable `GitHubCLIService.parseAccount(_:)` (1 MiB body cap,
    requires a non-empty `login`).
  - `gh repo create <name> --source . <--private|--public> --remote origin
    --push` → one call from behind `GitHubPublishSheet`'s explicit "Create
    & Push" confirmation. `--push` is always present in
    `publishArguments(name:visibility:)`; the coordinator never calls
    `publish` automatically.
- **Auth is entirely `gh`'s job.** Rafu never runs `gh auth login` or any
  other interactive sign-in flow, and never passes `--show-token`.
  `GitHubCLIError.notAuthenticated`'s message tells the user to run
  `gh auth login` in a terminal themselves.
- **Error taxonomy** (`GitHubCLIService.mapError(stderr:terminationStatus:)`,
  pure and unit-tested against representative stderr strings): stderr
  containing `gh auth login` / `not logged` / `authentication` maps to
  `.notAuthenticated`; `already exists` maps to `.remoteAlreadyExists`;
  everything else falls back to `.commandFailed(message)` using the trimmed
  stderr, or a generic "GitHub CLI command failed (\(status))" if stderr is
  empty.
- **No-logging rule.** `gh` stdout/stderr is never logged — the same
  redaction discipline `GitServiceError` already applies to `git`. Callers
  may surface only the mapped `GitHubCLIError.errorDescription` to the user.
- `GitHubAccountModel` is a `@MainActor @Observable` singleton: text-first
  login display, with a best-effort in-memory avatar fetch (never persisted,
  never blocks the account chip).

## Why it matters

Building or bundling a second GitHub OAuth/auth flow inside Rafu would
duplicate `gh`'s own credential storage and refresh logic, widen the attack
surface, and risk storing a token somewhere other than Keychain. Shelling
out to the user's already-authenticated `gh` keeps Rafu's GitHub feature
surface small and auditable, and it parallels the existing "use system
`/usr/bin/ssh`, never build a second SSH stack" invariant (AGENTS.md) —
see ADR 0015 for the durable-decision record.

## Reproduction or evidence

`Tests/RafuAppTests/GitHubCLIParsingTests.swift` (`@Suite("GitHub CLI
parsing")`) covers `GitHubCLILocator` precedence ordering (via the
injectable `fixedCandidates`/`environment` parameters, so it does not
depend on `/opt/homebrew` or `/usr/local` existing on the test machine),
`parseAccount` success/malformed/oversized cases, `publishArguments`
construction, `validateRepositoryName`, and `mapError` stderr-string
mapping.

## Verification

```bash
swift test --filter GitHubCLIParsingTests
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Services/GitHubCLIService.swift`
- `Sources/RafuApp/Models/GitHubAccountModel.swift`
- `Sources/RafuApp/Views/GitHubAccountStatusView.swift`
- `Sources/RafuApp/Views/GitHubPublishSheet.swift`
- `Tests/RafuAppTests/GitHubCLIParsingTests.swift`
- `docs/decisions/0015-github-publishing-via-system-gh.md`
- `Sources/RafuApp/Git/GitCommandRunner.swift` (the overridden-environment
  `/usr/bin/git` runner this deliberately deviates from)
