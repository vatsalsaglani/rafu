# `rafu ensemble` verbs

Targets `rafu ensemble` verb version 1. If `rafu ensemble status --json`
reports a different `verbVersion`, trust the CLI and re-read its `--help`.

The read-only grammar and JSON below mirror Rafu's verb-version-1 IPC
reference. The mutating surface mirrors ADR 0018's coordinator-token amendment
and the C8 CLI specification. Never invent a flag that those contracts do not
state.

## Trust classes

Read-only verbs require no token:

- `status`
- `artifact`
- `await`

Coordinator verbs require `RAFU_ENSEMBLE_TOKEN`:

- `run`
- `abort`
- `note`
- `grant`
- `propose-merge`

The token is an in-memory Rafu capability, not a provider credential. It dies
when Rafu quits and is never passed to worker children.

## Read-only verbs

### `status`

```text
rafu ensemble status [<run>...] [--tree] [--since <cursor>] [--json]
```

With no run ids, it returns every run in the matching open workspace. `--tree`
orders a coordinator before descendants while the JSON keeps one flat `runs`
array. `--since N` includes retained events whose cursor is greater than `N`.

```json
{
  "ensemble": {
    "_0": {
      "result": "status",
      "status": {
        "cursor": 42,
        "events": [],
        "runs": [
          {
            "label": "Parser",
            "runID": "run-a",
            "startedBy": "coordinator",
            "state": "running",
            "steps": [
              {
                "agentName": "implementor",
                "artifacts": [
                  "/Users/me/project/.rafu/runs/run-a/steps/01-implementor-a1/handoff/report.md"
                ],
                "attempt": 1,
                "evidencePath": "/Users/me/project/.rafu/runs/run-a/steps/01-implementor-a1",
                "index": 0,
                "model": "gpt-5.6",
                "provider": "codex",
                "state": "running"
              }
            ],
            "usageLines": [],
            "workflowName": "Implement"
          }
        ],
        "tree": false,
        "verbVersion": 1
      }
    }
  }
}
```

Optional `label`, `startedBy`, `gate`, and step `evidencePath` fields are
omitted when absent. Usage is present only when the provider reported it.

### `artifact`

```text
rafu ensemble artifact <run> <step> [--json]
```

`<step>` is a zero-based step index on the wire. The command returns the
absolute handoff artifact path for that run and step. A missing run or step is
exit 65.

```json
{"artifact":{"artifacts":["/Users/me/project/.rafu/runs/run-a/steps/01-implementor-a1/handoff/report.md"],"runID":"run-a","stepIndex":0},"result":"artifact"}
```

### `await`

```text
rafu ensemble await <run>... --state <state> [--any] [--timeout <sec>] [--json]
```

Without `--any`, every named run must enter a requested state. With `--any`,
the first matching run returns so the coordinator can review and refill a
batch while other runs continue. A user timeout is exit 75.

Stable state names:

```text
pending
running
awaitingGate
awaitingPlanGate
awaitingMergeGate
completed
failed
aborted
interrupted
merged
```

The subscription acknowledgement is:

```json
{"cursor":42,"result":"subscribed"}
```

Subsequent event frames use `kind` values `state`, `gate`, `note`, `merged`,
or `heartbeat`:

```json
{
  "at": 804306000,
  "cursor": 43,
  "kind": "state",
  "label": "Parser",
  "runID": "run-a",
  "startedBy": "coordinator",
  "state": "completed"
}
```

### `help`

```text
rafu ensemble --help
rafu ensemble help
```

If a filesystem entry named `ensemble` exists in the working directory, the
bare subcommand exits 64 and names `rafu ./ensemble` as the path
disambiguation.

## Coordinator verbs

Every verb in this section requires `RAFU_ENSEMBLE_TOKEN`.

### `run`

```text
rafu ensemble run <workflow> [options]
  --role <name>=<cli>[:<model>]   Bind or override a role at launch
  --input <key>=<value>           Values interpolated into the prompt
  --artifact <path>               Seed an input artifact by reference
  --base <ref>                    Branch point (default: current HEAD)
  --label <text>                  Human-readable node label on the canvas
  --detach                        Return immediately (default)
  --json                          Machine-readable result
```

```json
{
  "runID": "r-9f2",
  "workflow": "implement",
  "worktree": "/Users/v/.rafu-worktrees/project-r-9f2",
  "branch": "rafu/run-r-9f2",
  "state": "running",
  "startedBy": "r-8a1"
}
```

Every child is attributed to its coordinator through `startedBy`. Rafu, not
the model, creates the worktree.

Open the initial plan with `run --plan-gate` before spawning work. This
load-bearing gate is part of the coordinator workflow even when an older CLI's
general `run --help` excerpt omits it.

### `propose-merge`

```text
rafu ensemble propose-merge <run>... [--message <text>] [--json]
```

This verb never merges. It queues diffs at the human gate and returns
`"state": "awaiting_human"`. Follow it with `await <run>... --state merged`.

### `abort`

Stops a run started by this coordinator. The accepted design contracts do not
yet state stable arguments or flags for this verb. Do not guess: read
`rafu ensemble abort --help`.

### `note`

Posts a bounded line to the run timeline. The accepted design contracts do not
yet state stable arguments or flags for this verb. Do not guess: read
`rafu ensemble note --help`.

### `grant`

Reads this coordinator's remaining concurrent-run, total-run, provider,
usage-ceiling, and deadline grant so fan-out can be sized before it starts.
The accepted design contracts do not yet state stable arguments or flags for
this verb. Do not guess: read `rafu ensemble grant --help`.

## Exit codes

| Code | Meaning | Coordinator action |
|---:|---|---|
| 0 | Success | Continue. |
| 64 | Invalid grammar or collision | Fix a read-only call; if a mutating verb produced 64, stop and ask the user to update Rafu. |
| 65 | Malformed or missing file/run data | Correct the data; re-gate changed plan files. |
| 69 | No Rafu listener or matching open workspace | Stop and ask the user to run Rafu and open the workspace. |
| 75 | Grant exhausted or timeout | Ask the user to extend; never loop. |
| 77 | Missing/dead token or disallowed CLI | Stop and report; never retry with different arguments. |
