---
title: Git in Rafu
description: A review surface, not an autopilot — changes, diffs, hunks, stash, blame.
---

# Git in Rafu

Rafu's Git exists to answer one question well: *what did the agent (and I) actually
change?* `⌘⇧G` opens the Source Control surface; diffs open in the editor area, because
a diff is document content, not a floating panel.

## The surface

- **Changes** — staged, unstaged, and untracked files, grouped and labeled (never
  color-only)
- **Side-by-side and unified diffs** in the editor, syntax-highlighted with the same
  Tree-sitter grammars and theme tokens the editor uses — not plain text with a
  colored background
- **Hover on the new side.** For a working-tree diff of a saved file, hovering the
  right-hand (new) column resolves declarations and types through your LSP, same as
  hovering in the editor. The old side never gets hover — that text may not exist on
  disk anymore, so any answer about it would be a guess
- **History with a real commit graph** — lanes capped at eight with an overflow
  indicator, branch/tag/upstream chips, and pagination for long histories
- **Branches and worktrees** for orientation — worktrees get their own section
- **File-level staging** for the common case

## Hunk staging

For the times the agent's change is 80% right, you can stage a single hunk instead of a
whole file. Hunk staging is deliberately bounded:

- Available for **textual hunks of modified files** in live working-tree or staged diffs
- The exact bytes of the patch are preserved — Rafu slices the selected hunk and the
  file prologue from Git's own `diff` output and pipes it to `git apply --cached -`
- Stale context fails atomically; Rafu then refreshes the repository and diff
- Added, deleted, renamed, untracked, binary, and historical diffs keep whole-file or
  read-only behavior

## Stash

Stash is always an explicit action — there is no automatic stash. The Source Control
sheet offers an optional message and an include-untracked choice; the menu and command
palette offer the conservative tracked-only action. Apply, pop, and drop validate the
entry first, and pop/drop ask for confirmation, because they can remove the only
convenient reference to saved work.

## Blame, three ways — all opt-in

Rafu's blame is GitLens-inspired but deliberately quieter. Nothing annotates your
editor until you ask:

- **Inline blame** — ghost text after the caret line: author, relative time, summary.
  Toggled per window from the View menu or the palette; off by default. It runs one
  debounced `git blame --porcelain` for the focused **saved** file, caches per
  revision, and hides while the document is dirty.
- **Full-file blame** — per-line annotations down the whole buffer, from the same
  View-menu toggle family. Also off by default.
- **Blame File canvas** — an editor-hosted, read-only attribution table: line number,
  author, short commit, age, summary. One bounded blame process, discarded when you
  close it or switch files.

Hovering an annotation shows the commit card — author, relative and absolute time,
summary, sha chip — with Copy SHA and Show in History. Clicking a gutter change-strip
opens a **hunk peek**: the exact −/+ rows sliced from the already-captured patch
(capped at 200 lines), with a Stage Hunk action and no discard — review stays
non-destructive.

## Worktrees

The Worktrees section of Source Control lists your linked worktrees with branch,
ahead/behind, and a current marker — refreshed only when you expand it. You can open a
worktree in a new window, compare it with your current checkout, add one, or remove
one. See [Worktrees](/docs/worktrees).

## Committing

The commit form holds a subject and body; you can type it yourself or
[draft it from an explicit diff scope](/docs/commit-messages). Before the first
hook-capable action, Rafu explains that `git commit` can execute repository hooks and
asks whether you trust this workspace. Hook output is preserved and shown.

## What it won't do

- No persistent Git process — commands run bounded, cancellable, and on demand
- No automatic fetch, commit, push, stash, or diff transmission
- No destructive `reset` / `clean` UI in the initial release
- No shell strings: every invocation is an executable plus an argument array, with `--`
  before paths
