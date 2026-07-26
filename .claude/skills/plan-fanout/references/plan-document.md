# Plan document skeleton

One file per worktree, at `docs/plans/phases/<area>/<ID>-<slug>.md`. Every
section below earns its place — each exists because omitting it produced a
concrete failure in a previous run.

---

## `# <ID> — <one line saying what the agent will have built>`

Title the outcome, not the activity. "Rafu Lightning: a dev build that
cannot kill your editor" tells an agent what success looks like; "Build
variant work" does not.

## Status block

```
- **Status:** Ready. Branch: `<branch>` (from `main` AFTER <prereq> merges —
  verify `<exact file or symbol>` exists; missing ⇒ STOP and report).
  Wave N — parallel with <peers>.
- **Why now / why this exists:** the failure being prevented, in two or
  three sentences.
```

The prerequisite check must name a **file or symbol the agent can test for**,
never "after phase X merges" — a worktree can be cut from a stale HEAD, and
the agent needs a mechanical check. This has already caught one branch cut
128 commits behind.

The "why" paragraph is not decoration. Agents allocate effort by what the
prompt emphasises; stating the failure keeps them from polishing the cosmetic
part and skimping the load-bearing one.

## `## Goal`

What exists when this is done. Include what must **not** change — a re-host
that quietly redesigns is unreviewable.

## `## Read first`

Exact paths with the reason each matters, including line anchors where they
help: `Views/Foo.swift` (the `+` Menu at ~line 108), `docs/references/bar.md`
(the contract you must not break). Name the skill to use if one applies.

## `## Owned paths`

Every file this plan may touch, with the scope of each where partial:
`Sources/.../Protocol.swift` — **only** `SocketPath` (~line 164); another
plan edits the enum near line 36.

## `## Forbidden`

Name the peer plans and what they own. "Do not touch X (UX-02 owns it)" is
followed; "stay in scope" is not.

## `## Design contract`

The bulk. Numbered subsections, each with the exact shape to build — type
signatures, the enum cases, the ordering, the existing pattern to copy.
Where a decision could reasonably go two ways, make it and say why, so the
agent does not re-litigate it.

Call out anything **load-bearing** explicitly, with the consequence of
getting it wrong. "Missing one site means Lightning silently writes into the
user's real state — no error, discovered days later" is what makes an agent
consolidate rather than sprinkle suffixes.

## `## Tests`

The specific tests, not "add tests". Name the guard tests separately and say
what regression each prevents. Prefer source scans over checklists for
anything enumerable.

## `## Gates`

Standard four, plus anything specific. State explicitly whether
`build_and_run.sh` is permitted and why — the default is headless-only, and
an exception needs a reason (launching is the thing under test).

## `## Documentation deliverables`

Which reference note or ADR, and what it must contain. Remind the agent that
shared indexes are report rows, never edits.

## `## Handoff report`

What the report must contain beyond the standard: the decisions made, the
evidence for any claim that cannot be re-derived, and the manual checks the
coordinator must run.

## `## Goal-mode agent prompt`

A fenced block, self-contained, per
[`goal-mode-prompt.md`](goal-mode-prompt.md).

---

## Length

Long enough that the agent does no exploration to start; short enough to
read in one sitting. If a section is restating the codebase rather than
directing work, cut it — the agent can read the code, and a plan that
paraphrases it goes stale.
