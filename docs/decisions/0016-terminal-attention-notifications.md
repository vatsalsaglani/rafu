# ADR 0016: Terminal attention notifications with a bounded output snippet and reply

- **Status:** Proposed
- **Date:** 2026-07-21

## Context

`terminal-manager.md` stage T-E gives Rafu a per-session attention state
(`.bell`, raised when a backgrounded/unfocused terminal session receives
BEL — the signal agent CLIs such as Claude Code already ring on
finish/need-input). The phase document, written in advance of
implementation, locked three narrower positions that the user explicitly
reversed once the feature was in front of them:

1. It stated Rafu "never parses output content."
2. It scoped the optional system notification as "opt-in, off by default,"
   with authorization requested up front.
3. AGENTS.md's non-goal list says "no command palette injection into
   shells."

During implementation the user asked for the notification to carry a short
snippet of what the session actually printed (so "needs attention" is
distinguishable from "finished cleanly") and to let a reply typed directly
into the notification reach the waiting shell, without leaving Rafu or the
notification itself. This is a durable, user-directed change to three
previously locked positions and needs a decision record rather than a
silent contradiction.

## Decision

- **Bounded, ephemeral output read (reverses "never parses output
  content").** `RafuTerminalView.recentOutputSnippet` reads the terminal's
  VIEWPORT only (`Terminal.getLine(row:)` over on-screen rows, via
  `TerminalView`/`Terminal`, never `getBufferAsData`, which walks the
  entire scrollback and stays forbidden), caps the result at 6 lines / 512
  bytes, and strips control characters (`TerminalAttentionPolicy.snippet`).
  This read fires only at the moment a notification would actually post —
  never speculatively, never from a view body — and the result is never
  logged, persisted, or transmitted anywhere except that one notification
  body.
- **On by default with lazy authorization (reverses "opt-in, off by
  default" with up-front authorization).** Bell attention notifications are
  enabled by default. `TerminalAttentionNotifying.requestAuthorizationIfNeeded()`
  requests macOS notification permission the FIRST time a bell would
  actually notify — not at app launch — so the system prompt always has a
  visible cause. The notification CATEGORY (with its reply action) is
  still registered unconditionally at launch (`registerCategoryAndDelegate`),
  which itself never prompts for permission.
- **Narrowed, not repealed, "no command palette injection into shells."**
  Rafu still never composes, infers, or automatically executes a command.
  A notification reply relays the USER's own typed text — entered into a
  `UNTextInputNotificationAction` — into the exact session that raised the
  notification, and nothing else:
  - Routing uses a UUID this process minted for that session (never a
    path, host, or shell-identifying string) carried in
    `content.userInfo`; the reply handler resolves the live session from
    that UUID via `TerminalAttentionCenter.deliverReply`.
  - The reply text is sanitized to one line and capped at 1024 bytes before
    it ever reaches a pty (`TerminalAttentionPolicy.sanitizedReply`).
  - It is written to the pty exactly as the user typed it (an executable +
    file-descriptor write, matching AGENTS' standing "never interpolate
    into a shell command string" rule) — Rafu contributes no command
    text of its own.
  - If the target session has since died, the reply is dropped silently
    (no crash, no queued replay, no fallback session).
  - The reply action has no `.foreground` option, so responding never
    steals focus from whatever the user is doing.

## Alternatives considered

- **Keep the snippet feature but truncate/redact more aggressively (e.g.
  fixed placeholder text, no real output).** Rejected by the user — a
  generic "something happened" notification does not answer the actual
  question ("did it finish, or is it stuck").
- **Keep authorization at launch.** Rejected: prompting before any bell has
  ever fired gives the OS permission dialog no visible cause and trains
  users to dismiss it.
- **Route replies by session name/title instead of a minted UUID.** Rejected
  — names are user- or agent-set strings, not guaranteed unique or stable,
  and would reopen the shell-string-interpolation door AGENTS forbids.

## Consequences

- `terminal-manager.md`'s "never parses output content" language and its
  "opt-in, off by default" notification framing are both superseded by this
  ADR for the T-E feature specifically; every other non-goal in that phase
  document (no task runners, no auto-executed commands, no command blocks)
  stands.
- AGENTS.md's "no command palette injection into shells" non-goal is
  narrowed, not removed: Rafu still never composes a command; it relays a
  user's own text into a session the user was already notified about.
- **Residual privacy exposure, accepted, not a bug:** macOS Notification
  Center persists delivered notification bodies (including the output
  snippet) and may surface them on the lock screen, independent of Rafu's
  `.active` interruption level. Users who consider their terminal output
  sensitive should disable the notification preference
  (`TerminalNotificationPreferenceStore`).
- All `UserNotifications` framework usage is confined to exactly one file
  (`SystemTerminalAttentionNotifier.swift`, grep-verified:
  `grep -rn "import UserNotifications" Sources/`), so headless tests never
  construct a real `UNUserNotificationCenter` — a raw SwiftPM/`swift test`
  binary has no bundle identity and cannot post notifications. Tests use a
  spy conforming to `TerminalAttentionNotifying`.
- `script/build_and_run.sh` now ad-hoc signs the staged `.app` bundle,
  because an unsigned bundle cannot post user notifications on current
  macOS — required for this feature to work under the canonical launch
  script, not just for distribution signing.

## Revisit trigger

Revisit if a future phase wants notifications to carry more than a
viewport-bounded snippet (e.g. full-session summaries), or if reply routing
needs to target something other than a single live pty session.

## Related plan, reference, and implementation paths

- Plan: [`terminal-manager.md`](../plans/phases/terminal-manager.md) (stage
  T-E)
- Amended: [`0004-embedded-terminal.md`](0004-embedded-terminal.md)
- Reference: [`terminal-signals-and-shell-catalog.md`](../references/terminal-signals-and-shell-catalog.md)
- `Sources/RafuApp/Terminal/RafuTerminalView.swift`
- `Sources/RafuApp/Terminal/TerminalAttentionNotifier.swift`
- `Sources/RafuApp/Terminal/TerminalAttentionPolicy.swift`
- `Sources/RafuApp/Terminal/TerminalAttentionCenter.swift`
- `Sources/RafuApp/Terminal/TerminalNotificationPreferenceStore.swift`
