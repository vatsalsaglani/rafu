# Terminal manager — sessions panel, hide-vs-close, shell flavors, attention states

Status: planned, not started. Prepared 2026-07-21 against `main` plus the
uncommitted diff-highlighting and window-chrome work (baseline 888 tests,
0 warnings). Owner: one agent per stage; stages T-A/T-C can land together,
T-B is the big one, T-D/T-E follow.

## Why this phase exists

Rafu's user base works terminal-first: people live in `claude`, `codex`,
`cline`, `gemini` CLI sessions and use the editor around them. Today Rafu's
terminals are editor tabs (ADR 0004 as amended by ADR 0014), which breaks
down exactly where agent workflows need help:

1. **⌃\` kills the shell.** `WorkspaceSession.toggleTerminal()` calls
   `closeTerminalTab`, which terminates the process. Toggling the terminal
   away and back loses the running agent. Hide and close are different
   verbs; today Rafu only has close.
2. **Sessions are only discoverable as horizontal editor tabs.** With 4+
   agents running, the tab strip scrolls horizontally and every tab says
   "Terminal N" — no way to see at a glance what is running where or which
   session is waiting for input.
3. **One shell only.** Sessions always spawn `$SHELL`; there is no way to
   choose fish/bash/nushell, and no memory of a preferred choice.

External evidence this is the right bet (July 2026): an ecosystem of
third-party tools exists solely to manage parallel agent terminals —
[agent-deck](https://github.com/asheshgoplani/agent-deck) (session groups,
naming, status), [claude-terminal](https://github.com/Mr8BitHK/claude-terminal)
(tabbed manager, auto-naming, color tinting, worktree integration),
CodeAgentSwarm ("this terminal has finished / is waiting for your decision"),
plus a whole notification cottage industry
([agentbell](https://agentbell.dev/blog/claude-code-notification-when-done),
Telegram/Discord/iMessage bridges) whose only job is telling you an agent
stopped. The recurring pain points, in order: (a) not knowing when a session
finished or is blocked on input, (b) not being able to tell sessions apart,
(c) juggling window/tab sprawl beyond ~2 parallel sessions. VS Code's
terminal-tabs sidebar (name + icon + color + rename per session) is the
UX baseline users already know.

Rafu already has the right architecural bones: sessions live in
`WorkspaceTerminalManager` (`Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`),
SEPARATE from the editor tabs that display them, and the controller already
tracks live cwd via OSC 7. This phase makes the session list a first-class
surface instead of an implementation detail.

## Product decisions locked by this doc

- **Terminology.** "Flavor" = the SHELL program (zsh, bash, fish, nushell,
  …), not the terminal emulator. Rafu's emulator is SwiftTerm and stays so;
  iTerm/Ghostty/Warp are competitors, not embeddable engines. The UI says
  "Shell", never "flavor".
- **Sessions outlive their tabs.** A terminal SESSION (the running shell) is
  owned by `WorkspaceTerminalManager`. An editor TAB is just a view of one.
  Hiding a tab never kills the shell; only explicit close does. Sessions
  still all terminate on workspace switch and app quit (bounded, explicit —
  no daemon ambitions, no tmux).
- **No task runners, no auto-executed commands, no command blocks.** AGENTS
  non-goals hold. Rafu observes standard terminal escape sequences (OSC 0/2
  title, OSC 7 cwd, BEL); it never parses output content or injects
  commands.
- **Attention, not notifications.** v1 surfaces per-session attention state
  inside the app (badge on the rail, highlight in the panel). System
  notifications (NSUserNotification when a backgrounded session bells) are
  T-E, off by default.

## Stage T-A — hide vs close (the ⌃` fix; small, ship first)

Current: `toggleTerminal()` → `closeTerminalTab(selectedTerminalTabID)` →
`terminal.close(sessionID)` → shell SIGHUP. (`WorkspaceSession.swift:294-341`.)

New semantics:

- **⌃\` (Toggle Terminal):**
  - If the focused group's selected tab is a terminal → HIDE it: remove the
    TAB from the layout but keep the session alive in the manager
    (`parkedSessionIDs` concept below). Selection returns to the previous
    document tab.
  - Else if any parked (hidden but alive) session exists → REVEAL the most
    recently parked one as a tab in the focused group and select it.
  - Else → create a new session with the preferred shell (T-C).
- **⌃⇧\` (New Terminal):** unchanged, but uses the preferred shell.
- **Explicit close** (tab ✕, panel action, `exit` in the shell) still
  terminates the process. The tab ✕ on a terminal tab keeps meaning close —
  matching every other app — because hide has its own affordances (⌃\`,
  panel).

Implementation notes:

- `WorkspaceTerminalManager` gains `parkedSessionIDs: [UUID]` (MRU order) or
  equivalently each session gains `isPresentedAsTab: Bool`; deriving
  parked = sessions minus sessions referenced by any `.terminal` tab across
  the layout is more robust (no dual bookkeeping) — prefer deriving, via a
  helper on `WorkspaceSession` that walks `editorLayout` groups.
- `closeTerminalTab` splits into `hideTerminalTab(_:)` (layout removal only)
  and `closeTerminalTab(_:)` (layout removal + `terminal.close`). Audit ALL
  existing callers: the tab ✕ path, `toggleTerminal`, workspace-switch
  `shutdownAll` (unchanged), and tab-drag/close-others flows in
  `EditorLayout` — a terminal tab closed via generic layout paths must
  decide hide-vs-close explicitly; default generic layout closes to CLOSE
  (safe: no orphaned processes, matches today's contract in the
  `closeTerminalTab` doc comment).
- Shell exit (process termination callback in `WorkspaceTerminalController`)
  must remove the session from the manager AND close any tab showing it
  (today's behavior — verify it survives the split).
- ADR 0014 (terminal-as-editor-tab) gets an amendment: sessions may be
  parked without a tab; the "no orphaned process" guarantee moves from
  "closing the tab kills the shell" to "closing the SESSION kills the shell;
  workspace switch and quit kill all".

Tests (headless, both `swift test` and `--no-parallel`):
1. Toggle on a selected terminal tab parks the session (still in
   `manager.sessions`, no `.terminal` tab in layout).
2. Toggle again reveals the SAME session (same UUID) as a tab.
3. Two parked sessions reveal in MRU order.
4. Explicit `closeTerminalTab` still removes the session from the manager.
5. Workspace switch still shuts down parked sessions too.
6. Persistence: parked sessions are NOT restored across relaunch (terminal
   tabs already aren't — extend `TerminalEditorTabTests`).

## Stage T-B — Terminals panel in the utility area (the manager)

Add `case terminals` to `WorkspaceNavigatorMode`
(`WorkspaceSession.swift:6-17`; title "Terminals", symbol
`terminal` / `apple.terminal`), a third rail button in
`WorkspaceUtilityRail` (`WorkspaceNavigatorView.swift:~71`), and a
`WorkspaceTerminalsPanelView` rendered from `WorkspaceUtilityPanelView`'s
`panelContent` switch. NOTE: `WorkspaceNavigatorMode` is `Codable` and
persisted — a new case is forward-compatible, but verify decoding of an
old persisted value still works (it will; raw-value decode of existing
cases is unchanged) and that an UNKNOWN future case falls back to `.files`
rather than throwing (add the tolerant-decode now if absent).

Panel layout (reuse `RafuCardHeaderRow`, `RafuHoverRow`, `RafuChip`,
`RafuMetrics`; pin to top per the AGENTS panel rule, empty state expands):

- Header: "TERMINALS (N)" + trailing `+` button + chevron menu (T-C) +
  refresh not needed (live observation).
- One row per session, in creation order:
  - Color dot (session color, T-D) — never the only signal: pair with the
    status glyph.
  - Name (auto or user-set, T-D), middle-truncated.
  - Status glyph + accessibility label: `running` (quiet), `bell`
    (attention, accent), `exited(code)` (textMuted, shows code).
  - Secondary line: shell name + live cwd (`workingDirectory` from OSC 7,
    already tracked) relative to workspace root.
  - A "parked" affordance (e.g. `eye.slash` glyph) when the session has no
    tab.
- Row click: reveal — if the session has a tab, select it; if parked,
  insert a tab in the focused group and select it. Double-click = same
  (one behavior, no hidden distinction).
- Row context menu (every action also reachable via the row's trailing
  ellipsis button — AGENTS: no icon-only-context-menu-exclusive actions):
  Rename…, Color ▸ (palette swatches), Reveal, Hide Tab, Close (destructive,
  confirmation not needed — same as closing the tab today).
- Empty state: "No terminal sessions" + prominent "New Terminal" button +
  the ⌃\` / ⌃⇧\` shortcuts, mirroring the editor's SHORTCUTS card style.
- Rail badge: when any session is in `bell` state, the rail button shows a
  small accent dot + count in the accessibility label (state not by color
  alone: the dot plus the panel glyphs).

Implementation notes:

- The panel observes `session.terminal` (`WorkspaceTerminalManager` is
  `@Observable`) — no new state store. Status/name/color live on
  `WorkspaceTerminalController` (T-D/T-E fields).
- `WorkspaceUtilityPanelView` currently renders only when
  `session.descriptor != nil, session.navigatorMode != .files`
  (`WorkspaceWindowView.swift`) — terminals should work without an open
  folder? No: keep requiring a workspace (terminals start in the workspace
  root; the empty-window canvas already offers Open Folder). Document this.
- ⌘-path: add "Show Terminals" to the Rafu menu +
  `toggleUtilityPane(.terminals)`; palette command "Show Terminals".
  Suggested shortcut ⌘⇧T is TAKEN by convention (reopen closed tab) — use
  ⌃⇧T or leave it menu/palette-only in v1; verify against the shortcut
  grep before assigning anything.

Tests:
1. Mode round-trips through persistence; unknown mode decodes to `.files`.
2. Panel model: rows reflect manager sessions; parked derivation matches
   layout state (pure function over layout+manager — extract and test it).
3. Reveal on a parked session inserts exactly one tab and selects it;
   reveal on a shown session selects the existing tab (no duplicate).
4. Close from the panel removes session + its tab.
5. Rail-badge derivation (any-bell) as a pure function.

## Stage T-C — shell choice ("flavors") + preferred shell

- **Discovery** (`TerminalShellCatalog`, pure + tested): parse
  `/etc/shells` (absolute paths, `#` comments), keep entries that pass
  `FileManager.isExecutableFile`, dedupe by resolved basename keeping the
  first path, and additionally probe well-known Homebrew paths
  (`/opt/homebrew/bin/fish`, `/opt/homebrew/bin/nu`, …) that some setups
  never add to `/etc/shells`. Never spawn anything to probe — existence +
  executability only. Result: `[ShellFlavor]` (`name`, `path`, SF symbol).
  `$SHELL` (or `/bin/zsh`) is always first as "Default".
- **Preferred shell:** `@AppStorage("preferredShellPath")` (global, not
  per-workspace — matches "recently selected or opened"). Every session
  spawn records its shell as preferred. ⌃\`'s new-session path and ⌃⇧\`
  use it; if the stored path no longer exists, silently fall back to
  `$SHELL` and clear the stored value.
- **UI:** the panel `+` button spawns the preferred shell. A chevron
  (`chevron.down`) button next to it opens a menu of discovered shells —
  shown ONLY when the catalog has ≥2 entries, per the request. Menu items
  show name + path; selecting spawns that shell AND records it as
  preferred. The editor tab-strip's terminal `+` (if any) gains the same
  pair.
- **Spawn:** `WorkspaceTerminalController` gains `shellPath` (today it
  hardcodes `$SHELL` fallback `/bin/zsh` at `:95`); argv stays
  `[shellPath, "-l"]`-shaped, executable + args array, no string
  interpolation (AGENTS). Login-shell flag differences (fish uses `-l`
  too; nushell has no `-l` — pass no args for shells not known to accept
  it; keep a tiny per-basename table).

Tests: `/etc/shells` parsing (comments, blanks, missing file → default
only), dedupe/ordering, executability filter via temp dirs, preferred-shell
fallback when the stored path vanished, per-basename login-arg table.

## Stage T-D — identity: names and colors

- **Auto-name from the terminal title.** SwiftTerm surfaces OSC 0/2 title
  reports (`TerminalViewDelegate.setTerminalTitle`); agent CLIs set them
  ("✳ claude", codex, etc.). Controller keeps `reportedTitle: String?`;
  display name = `userName ?? reportedTitle ?? "\(shellName) \(index)"`.
  This is what makes the panel self-labeling for agent sessions with zero
  user effort — the single highest-leverage detail in this phase.
- **Rename:** panel context menu → inline TextField row edit (matches the
  file-tree rename pattern). `userName` sticks; clearing it returns to
  auto.
- **Color:** `sessionColor: TerminalSessionColor?` — an enum of ~6 theme
  palette tokens (accent, info, success, warning, error, textMuted), NOT
  raw colors, so themes restyle them. Shown as the row dot and as a thin
  leading strip on the terminal tab item in the editor strip (so tab strip
  and panel correlate). Color is always paired with name/status text —
  never meaning by color alone.
- Editor tab label for terminals switches from "Terminal N" to the same
  display name (middle-truncated at ~20 chars).

Tests: display-name precedence (user > title > default), title update
flows through, color round-trip, tab-label derivation.

## Stage T-E — attention states (the agent-workflow payoff)

Per-session `status`:

- `.running` — default.
- `.bell` — BEL received (SwiftTerm delegate `bell` callback) while the
  session is NOT the focused tab; cleared the moment its tab becomes
  selected. Agent CLIs ring BEL when they finish/need input — Claude Code
  does this out of the box (`terminal-config` docs) and users bolt entire
  notification systems on top of exactly this signal.
- `.exited(code)` — process terminated; row stays listed until closed so
  the exit code is visible (today the session vanishes instantly; keep
  auto-close for tab-visible sessions but let PARKED sessions linger as
  `.exited` rows — decide in implementation; simplest honest v1: keep
  today's auto-remove and show `.exited` only transiently, deferring
  lingering rows).
- Rail dot + panel highlight from `.bell` (T-B). Optional (off by default,
  Settings toggle): post a user notification when a parked/unfocused
  session bells — "Terminal 'claude' needs attention". Uses
  `UNUserNotificationCenter`, needs the permission prompt on first enable;
  keep strictly opt-in (AGENTS calm defaults).

Tests: bell sets state only when unfocused; selecting the tab clears it;
badge derivation; notification gate (enabled flag false → no post; use a
protocol seam over the notification center to keep tests headless).

## Explicit non-goals (v1)

- tmux/persistent sessions across app relaunch; SSH terminals (later
  phase); Warp-style command blocks; command palette injection into
  shells; per-command exit-code tracking (requires shell-integration
  scripts — revisit only with an explicit opt-in install flow); splitting
  terminals inside one tab; profile system beyond shell choice (env vars,
  args, ssh targets).

## Sequencing and sizing

| Stage | Size | Depends on | Ship gate |
|---|---|---|---|
| T-A hide/close | S | — | ⌃` round-trips a live shell; 6 tests |
| T-C shells | S/M | — | chevron appears only with ≥2 shells; catalog tests |
| T-B panel | M/L | T-A (parked concept), T-C (+/chevron) | panel manages, reveals, closes; rail badge |
| T-D identity | M | T-B | auto-names from titles; rename+color |
| T-E attention | S/M | T-B | bell → badge; opt-in notification |

T-A + T-C in one implementor pass; T-B alone; T-D + T-E together.

## Verification gates (every stage)

`swift build` 0 warnings; `swift test` AND `swift test --no-parallel`
green (baseline 888 + new); `./script/format.sh --fix` then `--lint`
clean; `./script/build_and_run.sh` launch pass covering: ⌃\` toggle
round-trip with a running process (`sleep 100`), ⌃⇧\` with a chosen
non-default shell, panel reveal/rename/color/close, bell → rail badge
(`printf '\a'` from a parked session), second window independence,
VoiceOver labels on rows and rail, Reduce Motion (no decorative row
animation).

## Documentation on completion

- Amend ADR 0004/0014: sessions-outlive-tabs lifecycle, the hide/close
  verb split, and the bounded-lifetime guarantee (workspace switch / quit
  kills all).
- Reference note: SwiftTerm delegate signals used (title, OSC 7 cwd, bell,
  process exit) and the no-content-parsing rule; `/etc/shells` catalog
  behavior.
- Update this doc's status + phases README row.

## Sources (research trail, July 2026)

- https://github.com/asheshgoplani/agent-deck
- https://github.com/Mr8BitHK/claude-terminal
- https://www.codeagentswarm.com/en/guides/run-multiple-claude-code-sessions
- https://www.codeagentswarm.com/en/guides/codeagentswarm-notifications
- https://agentbell.dev/blog/claude-code-notification-when-done
- https://dev.to/younann/stop-waiting-for-claude-code-get-notified-when-your-prompt-finishes-4b4a
- https://code.visualstudio.com/docs/terminal/appearance
- https://code.visualstudio.com/docs/terminal/basics
- https://docs.anthropic.com/en/docs/claude-code/terminal-config
- https://www.devtoolreviews.com/reviews/warp-vs-iterm2-vs-ghostty-2026
