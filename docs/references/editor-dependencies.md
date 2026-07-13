# Editor dependencies

- Applies to: Markdown preview and syntax-highlighting dependencies
- Last verified: Swift 6.2, macOS 15 deployment target, 2026-07-13

## Rule or observed behavior

Dependencies are pinned in `Package.swift` and kept behind Rafu-owned views and
services so they can be replaced without changing workspace state.

- `swift-markdown-ui` 2.4.1 (MIT) renders GitHub-Flavored Markdown, including
  tables, without one web view per document. Rafu supplies theme colors and keeps
  Mermaid fenced blocks in its native diagram renderer.
- `Neon` 0.6.0 (MIT) is the maintained TextKit token-application boundary for
  visible/open buffers. Language grammars remain separately replaceable; do not
  preload or parse the repository.
- Pin `SwiftTreeSitter` to 0.8.0 while using Neon 0.6.0. Neon's `from: 0.8.0`
  constraint admits later API-breaking `0.x` releases; resolving 0.25.0 fails
  under Swift 6.2 because `TreeSitterClient` calls a newly main-actor-isolated
  cursor initializer from nonisolated code.
- `SwiftTerm` 1.14.0 (MIT) provides the embedded terminal (ADR 0004) through
  `LocalProcessTerminalView` (VT100/xterm emulation plus a PTY-backed login
  shell). All SwiftTerm types stay inside `Sources/RafuApp/Terminal/`; the app
  talks only to `WorkspaceTerminalController` / `WorkspaceTerminalPanel`. The
  shell spawns lazily on first panel open, scrollback stays at the bounded
  500-line default, and its delegate callbacks arrive on the main thread
  (bridged with `MainActor.assumeIsolated`).

Inspect a dependency's tag, manifest, license, deployment target, and transitive
packages before changing its pin. Never expose third-party model types through
`WorkspaceSession`.

## Why it matters

Markdown tables and incremental highlighting are deceptively large parsing and
rendering problems. A boundary gives Rafu mature behavior while retaining control
of memory, themes, TextKit ownership, and future package replacement.

## Reproduction or evidence

- MarkdownUI: <https://github.com/gonzalezreal/swift-markdown-ui/tree/2.4.1>
- Neon: <https://github.com/ChimeHQ/Neon/tree/0.6.0>
- SwiftTerm: <https://github.com/migueldeicaza/SwiftTerm/tree/v1.14.0>

## Verification

Run `swift build`, `swift test`, and `./script/build_and_run.sh --stage`. Open a
Markdown table and common source files in the manual acceptance pass, then compare
resident memory with no files and several open buffers.

To reproduce the transitive-version failure, remove Rafu's explicit
`SwiftTreeSitter` pin, run `swift package update`, and build. Restore the pin and
run `swift package resolve` before continuing.

## Related code, ADRs, and phases

- `Package.swift`
- `Sources/RafuApp/Markdown/MarkdownPreviewView.swift`
- `Sources/RafuApp/Editor/SyntaxHighlighter.swift`
- `docs/plans/phases/pre-initial-push-workbench.md`
