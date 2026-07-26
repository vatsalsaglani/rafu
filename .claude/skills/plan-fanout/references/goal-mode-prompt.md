# Goal-mode prompt template

Ends every plan document, in a fenced block, self-contained — the agent may
receive only this. Six parts, each load-bearing.

---

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: <branch>. Preflight: run `git status --short --branch` ONCE. On this
branch + clean tree → proceed. Detached HEAD or wrong branch + clean tree →
checkout it if it exists, else `git checkout -b <branch> main`, then proceed
and say so. Dirty tree with edits you did not make → STOP and report.
Then verify the prerequisite: <exact file or symbol> exists. Missing ⇒ STOP
and report — <prereq plan> has not merged.

<If parallel:> You run in parallel with <peers>. Their files are off-limits
(the plan lists them). You share <file> with <peer>: you edit only <region>,
they edit <other region>. Stay in your region.

GOAL: implement <plan path> — <one sentence naming the outcome>. The plan
file is your authoritative design contract, edit list, and test list — read
it FIRST, then AGENTS.md, <governing docs>. Use <skill> for <aspect>.

WHY THIS EXISTS, so you weigh the parts correctly: <the failure being
prevented, and which part of the work is load-bearing versus cosmetic>.

HARD CONSTRAINTS: <invariants as absolutes, each with its consequence>. DO
NOT touch <files>, which <peers> own this wave. <Headless-only, or the
explicit exception and why.> Local builds are Rafu Lightning; never pkill or
pgrep a bare "Rafu", which is the user's editor.

DEFINITION OF DONE:
1. <observable outcome>
2. …
N. Work committed locally in verified stages; `rm -rf .build` as the last
   step. Never push, merge, rebase, or checkout main. A shared-file need is
   a HANDOFF — do everything independent of it first, then report the exact
   file, line, and a proposed diff — never a silent halt with zero commits.

FINAL REPORT (mandatory): delivered behavior; changed paths; test evidence
(names and counts, both modes); <decisions this plan must surface>; the
manual checks the coordinator must run; remaining risks; branch name; every
commit message; last commit id from `git rev-parse HEAD`.
```

---

## Why each part is there

**Preflight self-healing.** Worktree tooling frequently lands a detached
HEAD. Treated as a tripwire, agents burned entire runs declaring themselves
blocked. Treated as a setup detail to fix, they proceed. One check, one
decision — and never re-run an unchanged read-only check hoping for a
different answer.

**Prerequisite as a symbol, not a phase name.** A branch can be cut from a
stale HEAD; one was cut 128 commits behind and its prerequisites looked
absent. A file-or-symbol test is mechanical and cannot be misread.

**"Why this exists."** Agents allocate effort by emphasis. Without it, the
icon gets polished and the state isolation gets sprinkled. With it, the
weighting is explicit: "the safety comes from the process name and the state
separation — the icon is the finish."

**Constraints as invariants with consequences.** "Do not log the token" is
followed loosely; "the token is never persisted, never logged, never in a
manifest — a test must prove it" is followed exactly.

**Numbered definition of done.** Agents self-check against a numbered list.
Prose descriptions of doneness produce partial delivery.

**Mandatory report fields.** Branch, every commit message, and `HEAD` make
the merge mechanical. Test counts in both modes let the coordinator spot a
suite that silently shrank. Decisions surfaced here are the ones that would
otherwise be discovered during review.

## Tone

Write to a capable engineer who has not seen this codebase. State
constraints as facts about the system rather than as warnings about their
competence. Say what the failure looks like — an agent that understands the
failure mode makes better decisions in the cases the plan did not anticipate,
which is the whole point of goal mode.
