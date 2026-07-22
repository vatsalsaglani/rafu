---
title: Worktrees
description: Linked worktrees in Source Control — open, compare, add, remove. The agent in one tree, you in another.
---

# Worktrees

Git worktrees are the natural shape of agent work: the agent builds in one tree while
you keep a clean checkout in another. Rafu surfaces them where you already review —
the **Worktrees** section of Source Control (`⌘⇧G`).

## What you see

The section lists `git worktree list` with, for each entry: folder name, branch chip,
ahead/behind against its upstream, and a marker on your current checkout. The list
refreshes when you expand the section and after you add or remove a worktree — Rafu
does not watch sibling trees in the background, because a worktree list that polls is
a process you didn't ask for.

## What you can do

- **Open in New Window** — the worktree becomes its own workspace window, with the
  same editor, Git, and restoration as any other window
- **Compare with Current** — a two-ref diff between the worktree's branch and your
  current checkout, so you can review the agent's whole line of work before anything
  merges
- **Add Worktree…** — a sheet for a new or existing branch, defaulting to a sibling
  path
- **Remove…** — confirmed, and never forced; a dirty worktree stays on disk until you
  say otherwise

## What it won't do

- No background refresh of sibling worktrees — expansion is the refresh
- No per-worktree dirty badges for now; the section stays a list, not a dashboard
- Removal never passes `--force`

The flow this enables: point the agent at a worktree, keep your own checkout clean,
then **Compare with Current** when it reports back — the whole weave, reviewed as one
diff, before a single line lands in your tree.
