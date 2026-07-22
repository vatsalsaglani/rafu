---
title: Workspaces
description: One repository, one window — local today, SSH in a later release.
---

# Workspaces

A workspace is a folder — usually a Git repository or worktree — opened in its own
independent macOS window. Windows are never tabs inside one global super-window; they
behave like normal macOS windows, because they are.

## One window, one session

Each window owns exactly one workspace session: its file tree, open editors, tabs,
splits, selection, Git state, and restoration state. Nothing leaks between windows —
closing one workspace never disturbs another.

## Local workspaces

Open any local folder with `⌘O`, from the welcome screen, or from the recents list.
Rafu restores where you left off: open tabs, splits, selections, and scroll positions
come back as they were, and unsaved work survives a crash.

The file tree is lazy. Directories enumerate their children only when expanded,
generated directories are hidden by default (with a *Show Excluded Files* escape), and
useful ignored leaf files like `.env` stay visible — dimmed and marked ignored, because
they are usually the file you came for.

## External changes are first-class

Rafu exists beside terminal coding agents, so files changing underneath you is the
normal case, not an edge case:

| Buffer state | What happens |
|---|---|
| Not open | The tree and Git status refresh |
| Open and clean | Reloads automatically, preserving your selection |
| Open and dirty | You choose: Compare, Reload from Source, or Keep My Version |
| Deleted externally | Marked deleted; Save As or Close |
| Renamed externally | Reassociated by file identity when reliable |

A dirty buffer is **never** silently overwritten.

## SSH workspaces — in a later release

An SSH workspace is a folder that *stays on the remote machine*. The app's UI, editor
buffers, and unsaved changes remain local; a small versioned agent runs on the remote
host over a standard SSH channel and performs file operations.

The principles, already decided:

- **Your OpenSSH config is the authority.** Rafu invokes the same host alias you run in
  Terminal — `Include` files, `ProxyJump`, identity files, agents, security keys, and
  `known_hosts` all behave as they already do. Nothing is reimplemented.
- **One mental model.** The same editor, file tree, Git, and AI surfaces work over SSH.
  The remote nature shows in the title and a status indicator — `api — prod` — not in a
  forked UI.
- **Safe saves.** Writes are atomic and version-checked; if the remote file changed
  while you edited, you get a conflict, not an overwrite.
- **Disconnects don't lose work.** A dirty buffer keeps every unsaved edit locally,
  with Compare / Keep Mine / Reload on reconnect.

Host keys keep OpenSSH's normal behavior: unknown hosts require an explicit
confirmation, and a changed host key is a blocking error — never a one-click "ignore
and continue."

## Workspace trust

Local and remote folders carry a simple trust state:

- **Untrusted** — editing and viewing are allowed; executable features stay off.
- **Trusted** — Git commit hooks (and any later tools) may run.

Rafu explains this at the moment the first hook-capable action is attempted, not as a
vague warning at startup.
