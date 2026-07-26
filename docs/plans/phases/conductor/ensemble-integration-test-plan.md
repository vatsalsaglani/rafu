# Ensemble — real-CLI integration test plan (cheap models)

- **Status:** Ready to run (2026-07-26). Companion to
  [`ensemble-manual-test-plan.md`](ensemble-manual-test-plan.md), which covers
  UI behaviour. **This plan covers what only a real agent CLI can prove.**
- **Build:** Rafu Lightning (`./script/build_and_run.sh --verify`).
- **CLIs in scope:** Claude Code, Codex, OpenCode, Cline. Kimi, Gemini, and
  Cursor are out of scope for now.

## What this catches that 1703 headless tests cannot

Every existing test runs against `FakeConductorAdapter`. That proves the
engine — the FSM, gates, manifests, worktrees, the token, streaming — and
proves none of the following:

| Risk | Only a real run proves it |
|---|---|
| **The handoff contract holds with a real agent** | Completion is "artifact present + exit 0". Nothing has ever verified that a real CLI, given `RAFU_HANDOFF`, actually writes there. If it does not, every run fails and the engine is blameless. |
| Adapter argv is accepted | Flags were probe-verified from `--help`, never executed in a run. |
| The curated `PATH` is sufficient | All four are Node/Bun apps that shell out. `PATH` is deliberately minimal and not inherited. |
| Autonomy actually restricts | `readOnly` maps to plan/read-only sandbox modes we have never exercised. |
| Cross-vendor handoff | Can Codex consume the artifact Claude wrote, given only a path? |
| Concurrency between real CLIs | Three real agents at once may contend on config, session stores, or ports. |
| The skill teaches a coordinator correctly | The whole C8 surface assumes a real CLI can read the skill and drive `rafu ensemble`. |

## Cost control — read this before writing any task

The dominant cost is **not** the prompt. It is the agent deciding to explore
the repository. An agent told "add a comment to `Foo.swift`" will read files,
grep, and reason; an agent told "write this exact string to this exact path
and stop" does almost nothing.

Three rules make these runs cheap **and** deterministic:

1. **The task is fully self-contained in the prompt.** No task may require
   reading repository files. This is the single biggest cost lever.
2. **Assert on a sentinel string, not on judgement.** Every task writes a
   fixed token like `RAFU-E1-OK`. Pass/fail is `grep`, not opinion — which is
   also what makes these automatable later.
3. **Explicitly tell the agent to stop.** "Do nothing else. Do not read any
   other file." Agents are trained to be helpful; without this they will find
   work.

Expect each E1-class run to be a few thousand tokens end to end, most of it
the CLI's own system prompt rather than our task.

## Models

Use only cheap tiers. Verify the exact string each CLI accepts before the
run — these are the names, not necessarily the model IDs:

| Role | CLI | Model tier |
|---|---|---|
| Cheapest smoke | Claude Code | Haiku |
| Cheapest smoke | Codex | GPT-5.4 or GPT-5.3-Codex Spark |
| Cheapest smoke | OpenCode | a small open model (Kimi, GLM) |
| Cheapest smoke | Cline | its cheapest configured model |
| Coordinator | any of the four | Sonnet / GPT-5.6 Terra or Luna |

Never Fable, Opus, or GPT-5.6 Sol. If a model string is rejected, record the
error and fall back to the CLI's default rather than escalating tier.

## Before you start

Use a **throwaway repository**, not this one — E2 and E5 create worktrees and
apply diffs.

```bash
mkdir -p ~/rafu-ensemble-int && cd ~/rafu-ensemble-int
git init && echo "# scratch" > README.md
git add -A && git commit -m "seed"
mkdir -p .rafu/agents .rafu/workflows
```

`.rafu/agents/e1-claude.md` (repeat per CLI, changing `name`/`provider`/`model`):

```markdown
---
name: e1-claude
provider: claudeCode
model: haiku
autonomy: readOnly
handoffArtifact: report.md
---
Write exactly the text RAFU-E1-OK into the file report.md inside the
directory given by the RAFU_HANDOFF environment variable. Write nothing
else. Do not read, list, or modify any other file. Then stop.
```

`.rafu/agents/e2-advisor.md`:

```markdown
---
name: e2-advisor
provider: claudeCode
model: haiku
autonomy: readOnly
handoffArtifact: brief.md
---
Write exactly the text RAFU-E2-TOKEN-7391 into brief.md inside the
directory given by RAFU_HANDOFF. Write nothing else. Do not read, list, or
modify any other file. Then stop.
```

`.rafu/agents/e2-implementor.md`:

```markdown
---
name: e2-implementor
provider: codex
model: gpt-5.4
autonomy: worktreeWrite
handoffArtifact: result.md
---
Your prompt names an input artifact by absolute path. Read ONLY that file.
Then do exactly two things and stop:
1. Create a file named e2-output.txt in the current working directory whose
   entire contents are the token you read from that artifact.
2. Write that same token into result.md inside the directory given by
   RAFU_HANDOFF.
Do not read, list, or modify any other file.
```

`.rafu/workflows/e2.md`:

```markdown
---
name: E2 cross-vendor handoff
steps:
  - e2-advisor [gate]
  - e2-implementor <- brief.md
---
```

---

## E1 — Adapter smoke matrix (the artifact contract)

**The foundational test. If this fails for a CLI, nothing else about that CLI
is worth running.** Four single-role runs, one per CLI, identical task.

| # | Do this | Expect |
|---|---|---|
| E1.1 | New Run → single role → `e1-claude` → Run | Terminal tab opens running `claude` with your flags; run reaches `completed` |
| E1.2 | `cat .rafu/runs/<id>/handoff/report.md` | Contains `RAFU-E1-OK` |
| E1.3 | Repeat for `e1-codex`, `e1-opencode`, `e1-cline` | Each completes with its sentinel in its own handoff |
| E1.4 | Inspect `.rafu/runs/<id>/logs/output.log` for each | Real CLI output captured; no "command not found" |
| E1.5 | Check each `manifest.json` | `binding.provider`/`model` match what you asked for |

**Watch for (highest signal in the whole plan):** an agent that finishes
successfully but writes its artifact **somewhere else** — its own scratch
path, the repo root, or nowhere. That is the handoff contract failing, and it
would make every future run fail with "missing artifact" while the engine is
working perfectly. Record exactly where each CLI wrote.

Second: a "command not found" in the log means the curated `PATH` is missing
something that CLI shells out to — a real finding, not a flake.

**Negative check, E1.6:** temporarily change `e1-claude.md` to
`autonomy: readOnly` (already is) and change the task to "create a file
`escape.txt` in the current working directory". Expect the run to **fail or
the file not to exist** — read-only must actually restrict. If the file
appears, the autonomy mapping is cosmetic, which is a security finding worth
stopping for.

---

## E2 — Cross-vendor pipeline, gate, and merge

One run, two vendors, one gate, one merge gate. Claude writes a token; Codex
must read it from a path it was handed and act on it.

| # | Do this | Expect |
|---|---|---|
| E2.1 | New Run → workflow → `E2 cross-vendor handoff` → Run | Step 1 runs `claude`, completes, run parks at the step gate |
| E2.2 | Open the artifact from the run detail canvas | `brief.md` contains `RAFU-E2-TOKEN-7391` |
| E2.3 | Approve | Step 2 launches `codex` in a worktree |
| E2.4 | `cat .rafu/runs/<id>/steps/02-*/handoff/result.md` | Contains the same token — **the cross-vendor handoff worked** |
| E2.5 | Run reaches the merge gate; open the diff | Shows `e2-output.txt` added, containing the token |
| E2.6 | Apply to workspace | File lands in the repo; no auto-commit; worktree cleaned |

**Watch for:** step 2 completing without having read the artifact — check
`result.md` contains the *token*, not a paraphrase or an apology. An agent
that cannot resolve the path it was given breaks the entire handoff model,
and it will look like success unless you check the content.

Also watch the prompt in `steps/02-*/prompt.md`: it must contain the
**absolute path** to `brief.md` and not the file's contents. Artifacts pass
by reference; inlining them would be a regression.

---

## E3 — Three real CLIs at once

Start three single-role runs (E1 agents, different CLIs) as fast as you can
from the Runs panel.

| # | Do this | Expect |
|---|---|---|
| E3.1 | Start three runs back to back | All three run concurrently; the cap allows exactly 3 |
| E3.2 | Try a fourth | Refused with the typed cap reason, not a crash |
| E3.3 | Each finishes | Three distinct run directories, three sentinels, no cross-contamination |
| E3.4 | Check the graph canvas | Three independent roots; each node opens its own terminal |

**Watch for:** two CLIs of the same vendor fighting over a session store or
config lock. This is the failure mode headless tests cannot produce, and it
shows up as one run hanging while another succeeds.

---

## E4 — A real coordinator drives the verbs

The whole C8 surface, end to end, with a real CLI as coordinator.

Install the skill first: **Settings → Ensemble → Install for Claude Code**.

| # | Do this | Expect |
|---|---|---|
| E4.1 | ⌘⇧E → guided door → pick a coordinator CLI, cheap model → goal below → grant: 1 concurrent, 2 total → Start | Terminal tab opens; `RAFU_ENSEMBLE_TOKEN` is in its environment |
| E4.2 | Paste the goal if the CLI takes no prompt argument | — |
| E4.3 | Watch it call `rafu ensemble grant` | Reports 1 concurrent / 2 total remaining |
| E4.4 | It calls `rafu ensemble run e1-claude` | A child run appears, attributed `via <coordinator>` in the panel and graph |
| E4.5 | It calls `rafu ensemble await … --state completed` | Blocks, then returns when the child finishes — **streaming, not polling** |
| E4.6 | It calls `rafu ensemble artifact` and reports the token | Coordinator prints `RAFU-E1-OK` in its own terminal |

Goal to paste:

```
Use the ensemble-with-rafu skill. Do exactly this and nothing more:
1. Run `rafu ensemble grant` and tell me what is left.
2. Start one child run of the workflow/role `e1-claude`.
3. Await it reaching state completed.
4. Read its artifact and print the token it contains.
Do not plan, do not fan out, do not write any files.
```

**Watch for:** the coordinator inventing flags the CLI does not have. If it
does, that is the **skill's** fault, not the model's — `verbs.md` is supposed
to be the authoritative surface. Record the exact wrong invocation; it tells
us which part of the skill is ambiguous.

Also: a mutating verb returning **exit 64** means the installed Rafu predates
those verbs. Exit **77** means the token is missing or dead — check the
coordinator was launched from the sheet and not by hand.

---

## E5 — The consent loop closes

Continue in the same coordinator session to avoid a second start-up cost.

| # | Do this | Expect |
|---|---|---|
| E5.1 | Ask it to `run --plan-gate` a workflow | Run parks at a **plan gate**; **nothing spawns** — no worktree on disk |
| E5.2 | Edit the workflow file by hand while parked, then Approve | The **edited** version runs — approval re-parses |
| E5.3 | Let it finish to the merge gate; coordinator calls `propose-merge` | Gate is re-raised for you; **nothing is merged** |
| E5.4 | Approve the diff | Run reaches `merged`; the coordinator's `await --state merged` returns |
| E5.5 | Instead, on a second run, decline at the plan gate with a note | Run aborts; coordinator can read the note via `status` |

**Watch for:** anything merging without your approval. That is the one
result in this entire plan that is a stop-everything finding — ADR 0018's
gated merge-back is the feature's core promise.

---

## What I most want to hear about

1. **E1.2 / E1.3** — where each CLI actually wrote its artifact. Everything
   downstream assumes this.
2. **E1.6** — whether `readOnly` genuinely restricted writes.
3. **E2.4** — whether the token survived the cross-vendor hop.
4. **E5.3** — whether `propose-merge` merged anything. It must not.
5. **E4.6** — whether the skill taught the coordinator the right invocations,
   and where it guessed wrong.
6. Rough cost per scenario, so we know which are cheap enough to automate.

## Known limitations — do not report these

- Kimi, Gemini, and Cursor are out of scope here.
- Rafu never starts a run on its own; nothing happens without your click.
- The coordinator plans nothing in E4 by design — that is a cost control, not
  a capability limit.
- A parallel `swift test` flake is unrelated to any of this.

## If these prove cheap: what to automate

E1 is the automation candidate — fixed prompt, sentinel assertion, one CLI
per run, no human gate. A harness would need: a temp repo fixture, a way to
run the engine headlessly against a **real** adapter, an opt-in env guard
(`RAFU_INTEGRATION=1`) so normal `swift test` never spends money, and a
per-run timeout. E2 is possible with a scripted gate approval. E4 and E5 are
human-gate tests by construction and should stay manual.

Do not add any of this to the default suite. A test that costs money must be
opt-in, and CI must never run it.
