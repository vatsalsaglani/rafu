---
title: Find & replace
description: Immediate in-file find, workspace-wide search, and quick open.
---

# Find & replace

Search in Rafu follows one rule: frequent, keyboard-driven actions are immediate. No
decorating animation, no waiting on an index before the UI responds.

## Find in a file

- `⌘F` — find in the current file
- `⌥⌘F` — find and replace in the current file

Matches highlight in the buffer as you type, using the theme's find colors (the gold
active match you see on this site's hero window is the real `findMatchActive` token).
Replace is explicit and local to the open buffer; undo covers it in one step.

## Search the workspace

`⌘⇧F` switches the navigator to Search mode for workspace-wide find and replace. Search
runs in bounded, cancellable work — results stream in, and typing a new query cancels
the old one rather than queueing behind it.

## Quick open

`⌘P` opens Go to File. It queries a background file index with per-keystroke
cancellation, so it stays immediate even in large trees. The same palette hosts
commands at `⌘⇧P`.

## Occurrence-based editing

Sometimes the fastest search is a selection:

- `⌘D` — extend the selection to the next occurrence of the current selection
- `⌘⇧L` — select every occurrence in the file

Both are literal, honest matches of the selected text — one edit then renames them all,
and one `⌘Z` reverts the batch.

## Restoration-aware

Find state is per-document and participates in restoration: reopening a file doesn't
surprise you with a stale highlight — matches recompute only while find is actually
active.
