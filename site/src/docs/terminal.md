---
title: The terminal
description: Multiple lazy, bounded sessions per window — hide instead of kill, and know when one needs you.
---

# The terminal

Rafu was originally designed *beside* your terminal, with no emulator of its own. That
changed with an explicit product decision ([ADR 0004](https://github.com)): sometimes
the mend needs exactly one command — a `git log`, a `swift build`, a `docker compose
ps` — and leaving the window for it breaks the flow. It grew from there into a small
manager for the several sessions a repository actually needs (the agent's own shell,
a build watcher, a quick `git log`) without turning into a terminal emulator app.

## What it is

- **Editor tabs, not a dock.** Terminal sessions sit beside your files as tabs,
  toggled with `` ⌃` ``, the View menu, or the command palette
- A real VT100/xterm emulator (SwiftTerm, pinned and replaceable), so colors, `vi`, and
  `htop` behave — not a "dumb" output view
- Themed from the active Rafu theme: editor background and foreground, cursor color,
  editor font, and a 16-color ANSI palette derived from theme tokens

## Hide, don't kill

Closing a tab (✕, or the menu) terminates its shell — that's still explicit. But
`` ⌃` `` toggles *hiding*, not killing: the session keeps running underneath, and the
same shortcut reveals the most-recently-hidden one. Park a long build, glance at a
file, bring it back exactly where you left it.

The **Terminals** panel (Rafu menu → Show Terminals, or the command palette) lists
every session in the window — running, parked, exited — each with a status glyph and
the click target to bring it forward.

## Choosing a shell

New Terminal Tab (`` ⌃⇧` ``) starts your login shell (`$SHELL`, falling back to
`/bin/zsh`) at the workspace root. When more than one shell is discovered on the
machine — Rafu checks `/etc/shells`, `$SHELL`, and common Homebrew install paths for
zsh, bash, **fish**, and nu — the Rafu menu's **New Terminal With Shell** submenu lists
them by name and path, and the last one you pick becomes the new default.

## Naming and coloring sessions

Double-click a session in the Terminals panel to rename it — useful once you have
three shells and only two of them are named "zsh". Each session can also carry a
color: pick from the six theme-following presets or any color from the system color
picker; the color renders as the row's border, not another blob of chrome.

## When a session needs you

Terminal CLIs that ring the bell — an agent finishing a turn, or waiting on input —
raise **attention**. What happens next is a Settings choice (**Terminal attention**):
a system notification, [the notch companion](/docs/notch-companion), both, or neither.
The default is both.

The notification carries a short, bounded snippet of the session's own recent output —
never logged, never sent anywhere but that one notification — so you can tell "finished
cleanly" from "stuck" without switching windows. Type a reply directly into the
notification and it's relayed into that exact shell; Rafu never infers or executes it
itself.

## What it costs

- **Lazy:** no shell process exists until a tab is first opened
- **Bounded:** scrollback stays at a 500-line default per session
- **Explicit tabs:** every additional session is one you asked for — hiding keeps a
  shell alive, only closing ends it, so the process count is always something you
  chose
- Switching workspaces terminates all of that window's sessions; a died shell offers
  Restart / Close instead of auto-respawning

## What it will never do

- No task runners
- No automatic command execution — every shell runs only what you type, and a reply
  typed into a notification goes in as literal text, not a command Rafu decided to run
- No extension surface built on top of the terminal

The memory budgets Rafu advertises are measured with this honesty in mind: each shell
and its emulator join the footprint only after you first open that tab.
