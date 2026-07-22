---
title: The notch companion
description: A strip that merges into the physical notch — invisible until it isn't.
---

# The notch companion

On a notched Mac, Rafu adds a strip that lives in the menu bar's dead space above your
windows: closed, it's the exact width of the physical notch and nearly indistinguishable
from it. Hover, and it widens into a small control surface for every workspace window
you have open. Click, and it becomes a full panel. Nothing about it requires switching
windows or losing your place.

Turn it on or off in **Settings → General → Show notch companion** — on by default on
notched Macs, and it never appears on external or non-notched displays.

## Resting

A left glyph and a right count (your open editor windows), pinned to the physical
notch. If nothing needs you, that's all there is — no wings, no extra width, nothing
drawn where the camera housing would clip it.

The moment a session in any window rings the bell, the strip widens on its own to show
an accent dot and a count, even before you hover. It shrinks back the instant that
attention clears.

## Hover

Hovering (or clicking, which pins it open) expands the strip downward into a panel:

1. **Usage** — a muted line of real numbers for the coding agents you have connected
   (Claude, Codex, Cursor, and however many more you've set up), plus a
   `▸ N more providers` disclosure if you're tracking more than four. See
   [Usage tracking](/docs/usage-tracking).
2. **Editors** — one row per open workspace window: its name, a one-line git status
   (`⎇ main · 3± · ↑2`), and terminal-status chips for running, attention, and exited
   sessions. Click a row to bring that window forward. Past six windows, a filter field
   appears — type to narrow by name or branch.
3. **Attention** — a card for every session, across every window, that's waiting on
   you: the session's name, a bounded snippet of what it last printed, and a reply
   field. Type and send; the text goes into that exact shell, nothing inferred or
   executed on your behalf.

Escape, or clicking elsewhere, collapses the panel back to resting.

## What it will never do

- No content leaves the notch panel — replying types into the shell that's already
  running in your workspace, the same as replying from a
  [terminal notification](/docs/terminal)
- No color-only signals — attention and high-usage states always carry a number or a
  glyph alongside the accent color
- No always-on network activity — usage tiles are read-only and each provider is opt-in
  ([details](/docs/usage-tracking))
