---
title: The terminal
description: One lazy, bounded terminal per window — an editor tab for the one command you still need.
---

# The terminal

Rafu was originally designed *beside* your terminal, with no emulator of its own. That
changed with an explicit product decision ([ADR 0004](https://github.com)): sometimes
the mend needs exactly one command — a `git log`, a `swift build`, a `docker compose
ps` — and leaving the window for it breaks the flow.

The terminal is therefore deliberately bounded:

## What it is

- A first-class **editor tab**, toggled with `` ⌃` ``, the View menu, or the
  command palette — terminal sessions sit beside your files as ephemeral tabs
  (never restored on relaunch), not a permanent dock
- A real VT100/xterm emulator (SwiftTerm, pinned and replaceable), so colors, `vi`, and
  `htop` behave — not a "dumb" output view
- **Your login shell** (`$SHELL`, falling back to `/bin/zsh`), starting at the workspace
  root
- Themed from the active Rafu theme: editor background and foreground, cursor color,
  editor font, and a 16-color ANSI palette derived from theme tokens

## What it costs

- **Lazy:** no shell process exists until the panel is first opened
- **Bounded:** scrollback stays at a 500-line default
- **Explicit tabs:** additional tabs are created only by you (`` ⌃⇧` ``, the `+` button,
  menu, or palette) — each is one shell process, so the process count is always
  user-controlled. Closing a tab terminates its shell; hiding the panel keeps sessions
  alive
- Switching workspaces terminates all of that window's sessions; a died shell offers
  Restart / Close instead of auto-respawning

## What it will never do

- No task runners
- No automatic command execution — the shell runs only what you type
- No extension surface built on top of the terminal

The memory budgets Rafu advertises are measured with this honesty in mind: the shell
and emulator join the footprint only after you first open the panel.
