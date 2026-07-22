---
title: Getting started
description: What Rafu is, what it needs, and how to open your first workspace.
---

# Getting started

Rafu (રફૂ — *darning*) is a small, native macOS repository companion. It exists for the
focused edits that remain after a terminal coding agent — Codex, Claude Code, or
another — has done the larger weave: the `.env` value, the Dockerfile line, the
manifest the agent almost got right.

It is deliberately **not** an IDE. There is no extension marketplace, no embedded
coding agent, no AI chat, and no debugger. Every feature exists to support opening,
editing, reviewing, or committing a repository.

## Requirements

- macOS 15 or newer, on Apple silicon (the beta zip is `macos-arm64`)
- For source builds: Xcode 26.3 or a compatible Swift 6.2 toolchain

## Install

**Download the beta.** Grab `Rafu-v0.1.2-beta-macos-arm64.zip` from the
[latest release](https://github.com/vatsalsaglani/rafu/releases), unzip, and move
`Rafu.app` to `/Applications`. Beta builds are not yet notarized, so clear the
quarantine flag once, on that app only:

```bash
xattr -dr com.apple.quarantine /Applications/Rafu.app
```

Then open Rafu from Applications. Do not disable Gatekeeper globally — published
stable builds will use Developer ID signing and notarization instead.

**Or build from source:**

```bash
git clone https://github.com/vatsalsaglani/rafu
cd rafu
swift build
swift test
./script/build_and_run.sh --verify
```

The run script stages a real `dist/Rafu.app` bundle and opens it as a normal
foreground macOS app — bundling the `rafu` launcher under
`Contents/SharedSupport/bin/rafu`.

## The defining flow

```text
Open a local or SSH repository
        ↓
Review files changed by your coding agent
        ↓
Make focused edits — without launching a full IDE
        ↓
Review and stage Git changes
        ↓
Draft an editable commit message from an explicit diff scope
        ↓
Commit
```

## Your first five minutes

1. **Open a folder.** `⌘O`, or drag a repository onto the app. Each workspace gets its
   own real macOS window.
2. **Jump to a file.** `⌘P` and type a few characters — the palette queries a
   background index, so it stays immediate in large trees.
3. **See what the agent touched.** `⌘⇧G` opens Source Control: changed, staged, and
   untracked files, with side-by-side diffs in the editor area.
4. **Mend something.** Edit, then `⌘S`. External changes from the agent are detected —
   a dirty buffer is never silently overwritten.
5. **Commit.** Stage, optionally draft a message from the staged scope, edit it, and
   commit. Rafu asks before running repository hooks the first time.

## Where to next

- [Workspaces](/docs/workspaces) — local today, SSH in a later release, one window each
- [The editor](/docs/the-editor) — what the TextKit 2 editor does and doesn't do
- [Worktrees](/docs/worktrees) — the agent in one tree, you in another
- [The notch companion](/docs/notch-companion) — a strip that merges into the notch
  and expands into every open window's git status
- [Keyboard shortcuts](/docs/shortcuts) — the full, verified map
