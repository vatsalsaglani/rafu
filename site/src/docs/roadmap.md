---
title: Roadmap
description: Where Rafu stands, what ships next, and what is deliberately deferred.
---

# Roadmap

Rafu is built in gated phases, each with a written acceptance contract. This page
tracks the public shape of that plan; the repository's `docs/plans/phases/` directory
is the source of truth.

## Where it stands

**Current checkpoint: public beta** (`v0.1.2-beta`, on the
[releases page](https://github.com/vatsalsaglani/rafu/releases)). The app provides,
today:

- Restorable local workspaces in independent windows
- TextKit 2 editor groups with tabs, splits, multi-caret editing, and hibernation
- File and workspace find/replace, quick open, command palette
- Git changes, history with a commit graph, branches, side-by-side diffs, hunk
  staging, stash, and opt-in blame (inline, full-file, and canvas)
- Linked worktrees: list, open in a new window, compare, add, remove
- Tree-sitter highlighting for 11 languages, driven by the active theme
- Opt-in language servers — a transparent registry plus your own binaries — for
  definition, references, hover, and symbols
- GitHub-Flavored Markdown with native preview and bounded Mermaid diagrams
- Importable JSON themes — Indigo (dark) and Khadi (light) bundled, hot-reloaded
- Explicit AI: commit drafting with redaction and payload preview, plus
  `.gitignore` / `.dockerignore` suggestions that never write themselves
- GitHub publishing through your own `gh` CLI
- The `rafu` launcher with local IPC v1 (`rafu .`, `--goto`, window routing)
- A lazy, bounded embedded terminal — now living in editor tabs

## Next

| Phase | What lands |
|---|---|
| CLI v2 | `--wait` for editor `$EDITOR` flows |
| SSH workspaces | Remote folders through system OpenSSH, the versioned remote agent, safe saves, reconnect handling |
| Hardening & distribution | Developer ID signing, notarization, release automation decisions, license |

## Later, only if earned

Recorded as *optional future scope* — considered only after the core product is stable:

- Hunk-level staging beyond the current bounded form (done), built-in formatting for
  selected languages
- Remote port-forward management, remote terminal handoff
- Workspace tasks — without an extension platform

## Permanently out of scope

Extension marketplaces, embedded coding agents, AI chat, debuggers, collaboration, and
per-document WebViews are not "later" — they are **never**, by written decision. See
[the landing page](/#features) for the short version, or the product plan for the long
one.

## Open decisions

Public deployment target, final signing identity, license, and release channel are
deliberately undecided until distribution work begins. They are tracked in
`docs/decisions/open-decisions.md`.
