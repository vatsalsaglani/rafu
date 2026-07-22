---
title: The editor
description: TextKit 2 under SwiftUI — native text behavior, bounded memory.
---

# The editor

Rafu's editor is a real AppKit `NSTextView` on TextKit 2, composed inside the SwiftUI
shell. That boundary is deliberate: SwiftUI owns windows and chrome; the text system
owns text. Native input methods, undo, selection, and accessibility come from the
platform, not from a reimplementation.

## What it does today

- Tabs, splits, line numbers, current-line highlight
- Native undo/redo, cut/copy/paste, and standard macOS text behavior
- Find and replace in file (`⌘F` / `⌥⌘F`), go to line and column
- Indentation: tabs versus spaces, tab width, indent/outdent, auto-indent on return
- Toggle line comments (`⌘/`) for supported languages
- Line operations: move and duplicate
- Multiple cursors: `⌘D` next occurrence, `⌘⇧L` all occurrences, `⌥`-click to add a
  caret, `⌥⌘↑` / `⌥⌘↓` for carets above and below — one `⌘Z` reverts the whole batch
- Bracket matching and auto-closing pairs
- Soft-wrap toggle, dirty-tab indicator, external-modification handling
- Binary and unsupported-encoding warnings instead of garbled text

## The buffer rule

The full document text never lives in SwiftUI observable state. `NSTextStorage` owns
live text; SwiftUI observes only small metadata — identity, revision, dirty state,
selection, connection state. This is why typing stays immediate and memory stays
predictable: nothing on the typing path copies a document or invalidates a view tree.

## Syntax highlighting

Highlighting is real **Tree-sitter** — incremental, off the main thread — with a
bundled grammar set chosen around the files agent work actually produces:

```text
Plain text · Bash · Dockerfile · JSON · YAML · TOML
Markdown (+ inline) · Swift · Python · JavaScript · TypeScript · TSX
```

Detection uses extensions and exact filenames (`Dockerfile`, `Makefile`, `.env.local`,
`Package.swift`, `compose.yaml`, `.gitignore`…); grammar-less files get a bounded
regex fallback. Parsing is scoped to open buffers; there is no whole-repository
syntax index held in memory.

Colors come from the active theme's semantic syntax tokens — the same tokens this site
uses for code samples.

## Large files

Behavior is defined in advance, then tuned by measurement:

| Size / complexity | Behavior |
|---|---|
| Normal | Full syntax and editing features |
| Medium-large | Visible-range highlighting; expensive structure off |
| Very large | Plain text, no wrap, reduced decorations |
| Extreme or binary | Read-only warning, or a suggestion to use an external app |

## Restoration and hibernation

Tabs, splits, selections, and scroll positions restore across launches. Buffers you
haven't touched hibernate — their memory is released and rehydrated on return — so a
large working set doesn't tax an idle window. Unsaved changes are never hibernated
away; crash restoration covers them, including unsaved buffers from SSH workspaces.

## What it doesn't do

No extension host, no debugger, no collaborative cursors. Language intelligence
(go to definition and friends) is a separate, bounded system — see
[Language intelligence](/docs/language-intelligence).
