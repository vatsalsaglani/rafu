---
title: Agent terminals
description: One action opens the agent CLI you already use — the vendor's mark, your chosen model, no grant, no capture.
badge: next beta
---

# Agent terminals

Sometimes you don't want a pipeline — you just want `claude` or `codex` open in the
repository, authenticated, right now. An Agent Terminal launches a discovered vendor
CLI as an interactive [terminal session](/docs/terminal) with the same one-action
ergonomics as opening a shell.

## Launching one

**New Agent Terminal…** in the Rafu menu, or the agents section of the Terminals
panel: an icon grid of the CLIs Rafu can discover — Claude Code, Codex, OpenCode,
Cline, Kimi CLI, Gemini CLI, and Cursor CLI — each carrying the vendor's own mark.
CLIs that are missing, or known to be unauthenticated, stay visible but disabled,
with the reason spelled out. Logging in happens in the vendor's CLI, never in Rafu.

The session launches as an absolute executable plus an argument array — never a
shell string — with a curated `PATH` and nothing else: no inherited environment, no
provider credentials, and none of the variables an [Ensemble](/docs/ensemble) run
uses.

## The model you picked

Where a CLI's model flag has been verified against the installed binary's own help
output, the launcher offers the models that CLI will actually run and passes your
choice through. Where it hasn't, the CLI launches **bare** and the UI says why the
requested model was omitted — Rafu never guesses a vendor flag.

## Identity, honestly

The vendor's mark follows the session into the terminal tab and the Terminals panel,
and the process registers in Resources as **Agent Terminal** — distinct from an
Ensemble run's **Ensemble Agent** — so *what is this thing running* always has a
one-glance answer. Text labels remain alongside every mark for accessibility.

The marks are the vendors' own, used only to identify their CLIs: scaled and tinted,
never redrawn, never used as Rafu branding.

## Deliberately less than an Ensemble run

An Agent Terminal is *your* session, so it carries none of the Ensemble's machinery:
no grant, no capability token, no manifest, no output capture, no worktree
bookkeeping, no graph presence. It cannot acquire any of it later, either —
capability is decided at spawn, and a live session is never promoted.

Like every terminal session it is ephemeral: hidden, parked, and attention-notified
exactly as a shell is — and never restored after a relaunch.
