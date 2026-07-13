# ADR 0004: Adopt an embedded terminal panel

- **Status:** Accepted (supersedes the "no embedded terminal" initial non-goal)
- **Date:** 2026-07-13

## Context

The initial product scope explicitly excluded an embedded terminal: Rafu was
positioned beside a developer's own terminal, and the memory budget (idle
workspace roughly under 150 MB) argued against a resident emulator. During the
pre-initial-push acceptance pass the user gave explicit direction to add a
terminal, provided resident memory stays honest. That is a deliberate product
goal change, recorded here rather than silently contradicting AGENTS.md.

Alternatives considered:

1. **Hand-rolled PTY + NSTextView** — no dependency, but produces a "dumb"
   terminal (no cursor addressing, colors, vi/htop), which fails the "feels
   like Terminal/iTerm" expectation.
2. **WKWebView + xterm.js** — violates the native-interaction invariant and
   the one-webview-per-surface prohibition; heavier memory.
3. **SwiftTerm** (`migueldeicaza/SwiftTerm`, MIT, pinned exact 1.14.0) — a
   maintained native VT100/xterm emulator with `LocalProcessTerminalView`
   (PTY + login shell + NSView). Chosen.

## Decision

- Add SwiftTerm exact `1.14.0` behind a replaceable boundary: all SwiftTerm
  types stay inside `Sources/RafuApp/Terminal/`; the rest of the app talks to
  `WorkspaceTerminalController` and the `WorkspaceTerminalPanel` view only.
- The terminal is a **bottom panel of the editor area** (VSplitView), toggled
  with **⌃`**, a View-menu command, and a command-palette entry.
- **Lazy and bounded:** no shell process exists until the panel is first
  opened. Scrollback stays at SwiftTerm's bounded default (500 lines).
- **Multiple terminal tabs** (2026-07-13 amendment, user direction): the panel
  hosts a tab strip; each tab is one `WorkspaceTerminalController` (one shell
  process + emulator) owned by a per-window `WorkspaceTerminalManager`. Tabs
  are created explicitly (⌃⇧`, the + button, menu, or palette) — never
  automatically — so the process count stays user-controlled. Closing a tab
  terminates its shell; hiding the panel keeps sessions alive.
- The shell is the user's `$SHELL` (fallback `/bin/zsh`), launched as a login
  shell with the workspace root as the working directory.
- The panel is themed from Rafu theme tokens: editor background/foreground,
  cursor color, editor font, and a 16-entry ANSI palette derived from the
  theme's semantic colors.
- Lifecycle: switching workspaces terminates all sessions; a died shell shows
  Restart / Close Tab affordances instead of auto-respawning.

## Consequences

- AGENTS.md's initial non-goal list no longer includes the embedded terminal;
  the remaining non-goals stand.
- Memory claims must be re-measured with the panel open before distribution
  (shell + emulator expected in the tens of MB, only after first open).
- Terminal support does not extend to an extension host, task runners, or
  automatic command execution — the shell only runs what the user types.
