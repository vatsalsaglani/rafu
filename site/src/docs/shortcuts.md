---
title: Keyboard shortcuts
description: The current default map, verified against the app's command definitions.
---

# Keyboard shortcuts

The current default map. Menus are the source of truth — every action below also has a
visible menu path, per Rafu's interface rules.

## File & windows

| Action | Shortcut |
|---|---|
| New Untitled Document | `⌘N` |
| New Workspace Window | `⌘⇧N` |
| Open Folder… | `⌘O` |
| Save | `⌘S` |
| Close Editor (tab) | `⌘W` |
| Toggle Sidebar | `⌘B` |

## Getting around

| Action | Shortcut |
|---|---|
| Go to File… | `⌘P` |
| Command Palette… | `⌘⇧P` |
| Go to Line… | `⌃G` |
| Search Workspace | `⌘⇧F` |
| Show Source Control | `⌘⇧G` |
| Go to Definition | `⌃⌘J` or `⌘`-click an identifier |
| Go to Declaration | menu / palette |
| Find References | `⌃⌘R` |

## Editing

| Action | Shortcut |
|---|---|
| Find in File… | `⌘F` |
| Find and Replace in File… | `⌥⌘F` |
| Toggle Line Comment | `⌘/` |
| Select Next Occurrence | `⌘D` |
| Select All Occurrences | `⌘⇧L` |
| Add Caret Above / Below | `⌥⌘↑` / `⌥⌘↓` |
| Add caret at point | `⌥`-click |
| Undo / Redo | `⌘Z` / `⌘⇧Z` |

One `⌘Z` reverts an entire multi-caret batch edit.

## Terminal

| Action | Shortcut |
|---|---|
| Toggle Terminal (hide / reveal the most recent) | `` ⌃` `` |
| New Terminal Tab | `` ⌃⇧` `` |

New Terminal With Shell, Show Terminals, renaming a session, and picking its color all
live in the Rafu menu, the Terminals panel, and the command palette without dedicated
shortcuts — a keyboard-wide combination like `⌃⇧T` would collide with either a shell's
own readline bindings or an existing app shortcut, so menu + palette is the path in v1.

## Notes

- Markdown's Edit / Split / Preview mode control is per-document; check the menu for
  its current shortcut.
- Git hunk, stash, and blame actions live in the Rafu menu and command palette without
  dedicated shortcuts — an intentional choice, so future shortcut ownership stays
  unconflicted.
- The notch companion is pointer-first: hover or click the strip, `Escape` collapses
  it. There's no shortcut to open it from the keyboard yet.
- `⌘P` owns Go to File; the system Print command is deliberately replaced.
