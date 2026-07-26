# Ensemble consent, capability token, and grant

## Applies to

This note applies to the interactive Ensemble coordinator launch, its
process-local capability, `run`/`abort`/`note`/`grant` authorization, grant
accounting, worker-child isolation, coordinator terminal exit, and app
relaunch behavior. It does not grant inference credentials and does not
change the read-only `status`, `artifact`, or `await` verbs.

## Last verified

- 2026-07-26
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`)
- macOS 26.5.2 (25F84), arm64

## Rule

The capability lifecycle is:

```text
visible user start
  → mint 32 random bytes in memory
  → inject only into the coordinator terminal overlay
  → validate before every mutating request
  → account each successfully started child
  → revoke when that terminal exits or is explicitly closed
```

The token is base64url text only for transport through
`RAFU_ENSEMBLE_TOKEN`. Its value lives exclusively in
`ConductorEnsembleTokenStore` and the coordinator's pending
`TerminalProcessSpec.environment`. It is never stored in `UserDefaults`,
Keychain, a run manifest, output capture, a note, or a log; no error includes
it. Rafu does not persist coordinator terminal sessions, so an app relaunch
drops the store and requires a visible re-grant. Read-only verbs remain
available without it.

A coordinator is an interactive vendor CLI, not a worker run. Its process
spec uses the adapter-probed absolute executable, an argument array, the
workspace checkout as cwd, no output log, and exactly this environment
overlay:

```text
PATH=<Rafu curated path>
RAFU_ENSEMBLE_TOKEN=<opaque capability>
```

The interactive argv mapping is the existing AT-01
[Agent Terminal launch contract](agent-terminals.md#interactive-launch-probe-table).
C8-03 reused `AgentTerminalLaunchShape` directly. The coordinator path
exposed no gaps, so it made **no extensions** to that table: Claude Code,
Codex, OpenCode, Gemini CLI, and Cursor remain verified bare plus optional
`--model`; Cline remains verified `--tui` plus optional `--model`; Kimi
remains the explicitly marked bare-launch hypothesis with no model flag.
The goal stays visible in Rafu for the user; Rafu never synthesizes terminal
input or guesses a prompt argument.

## Grant enforcement

One token maps to one coordinator ID and this grant:

| Constraint | Check | Failure |
|---|---|---:|
| Live capability | Token exists in the in-memory store | 77 |
| Provider allow-list | Every resolved role provider is allowed | 77 |
| Concurrent children | Started children still in flight plus launch reservations are below `maxConcurrentChildRuns` | 75 |
| Total children | Recorded starts plus launch reservations are below `maxTotalChildRuns` | 75 |
| Deadline | Wall clock is before the optional deadline | 75 |
| Usage ceiling | Summed positive metered percentage-point deltas are below the optional ceiling | 75 |
| Window cap | The window's concurrent coordinator still has capacity | 75 |
| Notes bound | Another encoded line fits below 256 KiB | 75 |

Run IDs are reserved inside the main-actor token store before the asynchronous
workflow start. That reservation is part of concurrent and total accounting,
then becomes a recorded child only after the engine has a live manifest and
plan. A failed/cancelled start removes the reservation. This closes the actor
reentrancy window where two requests could both observe one remaining slot
before either recorded its child.

Usage enforcement follows C7's honesty rule. It sums only finite, positive
`percentPoints` values from the token's recorded child manifests. Token-only
or unresolved provider readings yield no consumed value, so a ceiling does
not trip. “No measurement” is never rewritten as zero.

Exit 75 means the proposed mutation is parked before another child continues;
it is not permission to retry silently. Exit 77 means the caller has no
authority and should stop. `abort` and `note` additionally require the target
manifest's `startedBy` to equal the token coordinator ID.

## Worker environment invariance

The capability overlay belongs only to the coordinator terminal.
`RafuConductorEnvironment.childEnvironment` remains exactly:

```text
PATH
RAFU_HANDOFF
RAFU_RUN_DIR
```

`EnsembleCoordinatorLaunchTests.workerEnvironmentInvariant` and the
request-service end-to-end test both compare the complete key set and assert
that `RAFU_ENSEMBLE_TOKEN` is absent. The worker engine receives no token
through its manifest, prompt, output capture, or environment.

## Notes and revocation

Coordinator notes append one JSON line `{at,from,text}` with `O_APPEND`, a
POSIX advisory write lock, a regular-file/no-symlink check, and a 256 KiB
pre-write bound. Text is nonempty and at most 1000 characters. Notes live
under `.rafu/runs/<id>/notes.jsonl`, because they may contain repository
content; the store publishes only the expected bounded note event and never
logs the line.

Natural terminal exit and explicit close converge on
`WorkspaceSession.coordinatorSessionDidEnd`: the session gets an `endedAt`,
the token is revoked, and a completed coordinator state event is published.
The operation is idempotent. A request that races after revocation sees exit
77.

## Why it matters

The coordinator is powerful enough to fan out paid, mutating work. A
process-local, scoped capability makes visible consent concrete without
turning Rafu into an inference credential authority. Reservations preserve
the grant across async suspension, typed failures let coordinators stop
predictably, and the invariant worker environment prevents a delegated child
from recursively acquiring orchestration authority.

## Reproduction and evidence

AT-01's installed-CLI evidence and probe commands remain recorded in
[`agent-terminals.md`](agent-terminals.md). C8-03 added no hypothesis or
verified row.

Focused and full verification:

```bash
swift test --filter EnsembleGrant
swift test --filter EnsembleMutating
swift test --filter EnsembleCoordinator
swift test
swift test --no-parallel
swift build
./script/format.sh --fix
./script/format.sh --lint
rg -n "RAFU_ENSEMBLE_TOKEN" Sources/RafuApp | rg -v Ensemble
rg -n "print\\(|Logger|os_log" Sources/RafuApp/Conductor/Ensemble
```

The tests prove mint/validate/revoke, every 75/77 row, unresolved-meter
behavior, capability propagation through the CLI DTO, real workflow-engine
manifest attribution, status tree grouping, note persistence/event/bound,
the tighter window cap, exact coordinator and worker environments, terminal
reveal, and post-exit rejection.

## Related code, ADRs, and phases

- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleGrant.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleRequestService.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleNoteStore.swift`
- `Sources/RafuCore/Ensemble/`
- [`ensemble-ipc-verbs.md`](ensemble-ipc-verbs.md)
- [`conductor-pty-spawn-and-child-environment.md`](conductor-pty-spawn-and-child-environment.md)
- [`agent-terminals.md`](agent-terminals.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)
- [`C8-03-capability-token-and-mutating-verbs.md`](../plans/phases/conductor/C8-03-capability-token-and-mutating-verbs.md)
