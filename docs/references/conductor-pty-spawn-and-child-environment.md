# Conductor PTY spawn: `forkpty` under parallel tests, and the child's missing `PATH`

- Applies to: `Sources/RafuApp/Conductor/` (adapter `invocation(...)` and
  `RafuConductorEnvironment`), `Sources/RafuApp/Terminal/`
  (`WorkspaceTerminalController`'s `TerminalProcessSpec` seam), and any
  phase that spawns an external agent CLI through the PTY rather than the
  login shell
- Last verified: Swift 6.2 / macOS 26 / SwiftTerm 1.14.0 / 2026-07-24 (phase C0)

## Rule or observed behavior

### 1. A real PTY spawn cannot be asserted under parallel `swift test`

SwiftTerm's `LocalProcess.startProcess` spawns via `forkpty()`. A real PTY
spawn performed inside the `swift test` process:

- passes when run in isolation,
- passes under `swift test --no-parallel`,
- **fails deterministically (3 of 3 attempts) under plain `swift test`**.

The failure shape is not an error: the child *appears* to spawn (`shellPid`
is set, `running == true`), then produces no output and never exits within
a 30 s wait. Cause: `fork()`-ing a heavily threaded process — which the
parallel swift-testing runner is — is not viable. Only the forking thread
survives into the child, so any work in the child that depends on another
thread's lock or state hangs forever.

**Rule:** PTY spawn behavior is verifiable only (a) inside a mounted view,
where `WorkspaceTerminalController.makeOrReuseView` is reachable at all, or
(b) under `swift test --no-parallel`. Never assert real PTY spawn in the
parallel gate.

C0's substitute — three `Foundation.Process` (`posix_spawn`) tests that
verify the *resolved launch* for real rather than the PTY transport:

1. exit status + stdout of the resolved executable/argv;
2. a hostile prompt string
   (`brief; rm -rf / and $(whoami) and backtick-id`) surviving as **one
   unexpanded `argv` element**, asserted against `NSUserName()` so that any
   shell expansion would be visible;
3. `/usr/bin/env` proving the child receives exactly the resolved
   environment.

True PTY execution is deferred to C1, which owns the run engine and can
verify it inside a mounted view.

### 2. SwiftTerm gives PTY children no `PATH` at all

SwiftTerm 1.14.0's `Terminal.getEnvironmentVariables()`
(`Terminal.swift:5872`) has **`"PATH"` explicitly commented out**. It
supplies `TERM`, `COLORTERM`, `LANG`, plus `LOGNAME`/`USER`/`DISPLAY`/
`LC_TYPE`/`HOME` when present — and nothing else.

With no `PATH`, `execvp` falls back to `confstr(_CS_PATH)`, roughly
`/usr/bin:/bin`. That reaches neither Homebrew nor `~/.local/bin`. Every
CLI on the Conductor roster is a Node/Bun program that resolves its
interpreter via shebang and then shells out to `git`, `rg`, or `node`, so
an empty search path fails the child at its **first subprocess**, not at
launch — a confusing, late failure.

Two adjacent API facts that are easy to get wrong:

- `startProcess`'s `environment` parameter is `[String]?` of
  `"KEY=VALUE"` strings, **not** a dictionary.
- With `execName == nil`, SwiftTerm inserts `executable` as `argv[0]`
  (`LocalProcess.swift:499-511`).

**Resolution shipped in C0:** `RafuConductorEnvironment.curatedPath` — a
fixed, auditable, deliberately **not-inherited** list:

```
/usr/local/bin : /opt/homebrew/bin : ~/.local/bin : /usr/bin : /bin : /usr/sbin : /sbin
```

where `~` is expanded from `FileManager.homeDirectoryForCurrentUser`.

Forwarding the user's real `PATH` was considered and rejected: it is
unbounded, user-mutable trust reaching an agent process, and ADR 0018
commits the child environment to being minimal and explicit.

Version-manager shim directories (nvm, fnm, volta) are deliberately **not**
guessed at. An adapter whose probe finds a CLI somewhere else MUST prepend
that executable's own directory to `PATH` in its `invocation(...)`. The
shared C0 tests assert a **superset** of the C0 environment keys precisely
so an adapter phase can do that without editing a shared file.

This problem is unique to the process-spec path. The ordinary login-shell
terminal sources the user's profile and is unaffected.

## Why it matters

C1's entire mission is spawning through the `TerminalProcessSpec` seam, and
C1 runs in an isolated worktree that cannot see the C0 review. Without this
note, finding 1 reads as a flaky test (tempting a retry loop or a sleep)
and finding 2 reads as "the agent CLI is broken on this machine". Both
cost hours to rediscover, and finding 2 has a security-shaped wrong answer
(inherit the user's `PATH`) that looks like the obvious fix.

## Reproduction or evidence

- Finding 1: a real PTY spawn test run 3× under plain `swift test` hung at
  30 s each time with `shellPid` set and `running == true`; the same test
  passed in isolation and under `swift test --no-parallel`.
- Finding 2: read directly from the pinned SwiftTerm 1.14.0 sources —
  `Terminal.swift:5872` (commented-out `PATH`) and
  `LocalProcess.swift:499-511` (`argv[0]` insertion).
- C0 gate results with the substitute tests in place: `swift build` exit 0
  with no warnings attributable to a C0 file; `swift test` 1362 tests in 60
  suites, exit 0; `swift test --no-parallel` 1362 tests, exit 0;
  `./script/format.sh --lint` exit 0.

## Verification

```bash
swift build
swift test
swift test --no-parallel
./script/format.sh --lint

# No shell interpolation anywhere in the Conductor tree (argv arrays only):
rg -n "/bin/sh|bash -c|NSTask" Sources/RafuApp/Conductor   # expect 0 hits
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Conductor/ConductorCore.swift` (adapter `invocation`
  contract; `RafuConductorEnvironment`)
- `Sources/RafuApp/Conductor/Adapters/` (per-phase adapters that may
  prepend a probe-discovered directory to `PATH`)
- `Sources/RafuApp/Terminal/` — the `TerminalProcessSpec` seam
- [`terminal-signals-and-shell-catalog.md`](terminal-signals-and-shell-catalog.md)
  — the login-shell path this note contrasts with
- [`conductor-file-contracts.md`](conductor-file-contracts.md) — the
  `.rafu/` side of the same invocation contract
- [`../decisions/0018-conductor-external-agent-orchestration.md`](../decisions/0018-conductor-external-agent-orchestration.md)
- [`../plans/phases/conductor/C0-shim.md`](../plans/phases/conductor/C0-shim.md)
