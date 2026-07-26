# Ensemble orchestration patterns

These are durable, cross-vendor, human-gated operations. They are not
in-process function calls: an `await` may span a coffee break or an app
relaunch.

## Primitive equivalence

| Graph-engineering primitive | Ensemble equivalent |
|---|---|
| `agent()` with a schema | `run` with a role whose agent file declares its artifact shape |
| `parallel()` barrier | Several `run` calls, then `await --state completed` |
| `pipeline()` staggering | `await --any`, judge one result, then launch the next |
| Router node | Read an artifact and choose the next `run` yourself |
| Verifier or adversarial vote | Launch N review runs over the same evidence and tally them yourself |
| Worktree isolation | Built in: Rafu creates one worktree per child run |
| Loop-until-dry | Keep a `seen` set and stop after K empty rounds |
| Budget-aware scaling | Call `grant` before every round |

## Recipe 1: fan out, then verify

1. Write the finder, skeptic, and workflow files, then open the workflow with
   `run --plan-gate`.
2. After the user approves, call `grant`.
3. Split the target deterministically. Launch no more children than the
   remaining concurrent allowance.
4. Use `await --any --state completed`. On each completion, read `artifact`,
   add every finding to `seen`, and refill the batch if the grant permits.
5. Dedupe locally; do not spend another agent on `flatMap` and `Set` work.
6. Launch several skeptic runs over each candidate artifact.
7. Tally the skeptic artifacts yourself. Report the survivors. A read-only
   audit has no merge gate.

## Recipe 2: staggered implementation loop

1. Write all known agent/workflow files and the first dependency plan. Open
   them with `run --plan-gate`.
2. Call `grant`, then launch independent work with explicit
   `--role <name>=<cli>[:<model>]` bindings and labels.
3. Call `await --any --state completed`. Read the first completed artifact
   while slower children continue.
4. If a later plan depended on that result, launch it immediately rather than
   waiting at a full barrier.
5. Launch review runs over completed work, read their artifacts, and judge.
6. If defects survive, launch a fix run. Otherwise call `propose-merge` for
   the clean run ids.
7. Call `await --state merged`. A rejection is input to the next plan, not an
   engine failure; read the user's note and re-plan.

Rafu launches, isolates, captures, and gates. The coordinator makes every
planning and judgment decision.

## Recipe 3: loop until dry

1. Initialize `seen` to every finding ever observed and set `dryRounds = 0`.
2. At the top of each round, call `grant`. If exhausted, stop and ask the user
   to extend.
3. Fan out finder runs with different lenses, within the current grant.
4. Await completion, read artifacts, and dedupe against all of `seen`.
5. If nothing is new, increment `dryRounds`; stop after the chosen number of
   empty rounds.
6. If anything is new, reset `dryRounds`, add every new item to `seen`, then
   launch skeptic runs.
7. Launch fix runs only for verified findings.
8. Call `propose-merge`, then wait for the human decision with
   `await --state merged`.
9. Begin another round only after checking `grant` again.

Never dedupe only against confirmed findings. A rejected finding must remain
in `seen`, or it will reappear forever and the loop will not converge.
