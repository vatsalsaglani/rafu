# Ensemble canvas (round 2)

- Status: Implemented; awaiting macOS verification (user direction, 2026-10-18). Base: `main` at `5e01dca`.
- Integration branch: `claude/rafu-macos-redesign-nqcu7h` (restarted from `main`).
- Earlier spec still applies for visual rules: `macos-redesign.md`,
  `docs/references/macos-redesign-visual-system.md`, `canvas-interaction.md`.
- Past ADRs do not block new work (user direction, clarified 2026-11-01).
  When new work conflicts with an earlier decision, the new direction wins.
  Still record each new durable decision as an ADR in `docs/decisions/`, and
  when it conflicts with an older ADR, record the conflict there: amend or
  supersede the older ADR and name it in the new one.

## User direction (summary)

1. Fix the Canvas: a blue focus border is drawn around the board; dragging the
   empty board does not pan; dragging files from the Files tree onto the board
   does not work.
2. Fix editor split view: dragging a tab to the left/right edge must split.
3. Remove the old Ensemble feature (runs, workflows, coordinator, graph) and
   rename **Canvas → Ensemble** in every user-visible string. One concept.
4. Agents in an Ensemble orchestrate each other through MCP tools exposed by
   Rafu: read the Ensemble, create/edit notes and nodes, add terminals and start
   agent CLIs or commands in them, create edges/relationships, go live, send
   tasks, open apps and inspect them. Ship a Rafu skill/plugin for Claude Code
   and Codex that teaches this.
5. Diagrams on the Ensemble: Mermaid rendered natively, and an Excalidraw-like
   whiteboard (shapes, arrows, freehand, text, dropped PNGs).
6. Our own saved format for an Ensemble.
7. The right agent SVG icon (Claude, Codex, …) everywhere in the app.
8. Use the empty titlebar row (workspace name, drag, double-click zoom, or better).
9. Native apps visible directly in the node, with no screen sharing.
   **Removed 2026-11-06** on the user's direction (ADR 0025 Amendment 3).
10. Notch HUD rebuilt like Cider (`/home/user/vatsalsaglani/cider`, same
    author): mascot, now playing, Ensembles and agents, usage.
11. Make it look better.

**Platform fact for item 9 (feature removed 2026-11-06):** macOS has no public API to embed another app's
live window in our view. Screen capture needs Screen Recording permission. The
chosen approach is **docking**: with the user's Accessibility permission, Rafu
moves and sizes the real app window so it sits exactly over the node and follows
pan/zoom/scroll; the user interacts with the real app. Without permission the
node shows the app icon and an explanation with "Open Accessibility Settings".

## Workstreams and owned paths (all under `Sources/RafuApp/` unless noted)

| ID | Model | Workstream | Owns |
|---|---|---|---|
| X1 | Opus | Canvas fixes, interaction, node polish | `Canvas/Views/WorkspaceCanvasView.swift`, `Canvas/Views/CanvasCard*.swift`, `CanvasBar.swift`, `CanvasAddMenu.swift`, `CanvasFileDropDelegate.swift`, `Canvas/Adapters/CanvasScrollBridge.swift`, `CanvasTerminalCard.swift`, `CanvasWebCard.swift`, `CanvasRepositoryCards.swift`, `Canvas/Integration/CanvasBoardState.swift` (interaction parts), `CanvasViewportActions.swift`; the Files-tree drag source (`Views/WorkspaceSidebarView.swift` drag code only) |
| X3 | Sonnet | Remove old Ensemble feature | `Conductor/Run/**`, `Conductor/Library/**`, `Conductor/Ensemble/**` except `ConductorSkillInstaller.swift`, `Views/Conductor*`, `Views/Ensemble*`, Ensemble aux tabs/routes/commands/rail entry, `Sources/RafuCore/Ensemble*` + `rafu ensemble` CLI, their tests. KEEP agent CLI support: `ConductorCLIID`, `ConductorCLIIcons`, `Conductor/Adapters/**`, `ConductorAdapterRegistry`, model catalog/resolution/cache, anything the Agents settings pane or terminals use. |
| X4 | Opus | Agent orchestration MCP tools + Rafu skill/plugin | `Sources/RafuCore/CanvasBridge/**`, `Canvas/Integration/CanvasLiveBridge.swift`, new `Canvas/Integration/CanvasAgentActions.swift`, `Conductor/Ensemble/ConductorSkillInstaller.swift`, `Settings/EnsembleSettingsTab.swift`, new skill/plugin resources under `Resources/AgentSkills/`, `Canvas/Integration/CanvasTerminalBootstrap.swift`, related tests |
| X5 | Opus | Whiteboard, Mermaid node, file format | `Canvas/Domain/**` (new card kinds; keep `CanvasConnection` stable), `Canvas/Persistence/**`, `Canvas/Integration/WorkspaceCanvasStore.swift`, new `Canvas/Whiteboard/**`, new `Canvas/Adapters/CanvasMermaidCard.swift`, UTType/document registration in `Resources/` plist template and `App/` open-file routing for the new extension |
| X6 | Opus | Native app docking (**removed 2026-11-06**) | `Canvas/Adapters/CanvasNativeAppCard.swift`, `CanvasPreviewLoader.swift`, `CanvasWindowCloseGuard.swift`, new `Canvas/Integration/CanvasAppDocking.swift` |
| X7 | Sonnet | Notch HUD like Cider | `Terminal/Notch*.swift`, `Views/Notch*.swift`, new `Notch/**`, mascot assets in `Resources/Mascot/`, notch settings rows in `Settings/RafuSettingsView.swift` (General notch section only) |
| X8 | Sonnet | Workbench: titlebar, tab split, agent icons, polish | `Views/WorkspaceWindowView.swift`, `Views/FlatWindowChrome.swift`, `Views/EditorTabSwitcherView.swift`, `Editor/EditorTabSwitcher.swift`, `Editor/EditorLayout.swift`, `Views/EditorCanvasView.swift` (tab bar + group drop zones), `Support/Rafu*Styles.swift`, new `Support/AgentIdentity.swift`, `Views/WorkspaceTerminalsPanelView.swift` (icons only), `Views/WorkspaceStatusBar.swift`, `Views/CommandPaletteView.swift` |

After X1–X8 merge, one sequential **R (rename) pass** changes user-visible
"Canvas" to "Ensemble" everywhere. Workstreams must NOT do that rename
themselves (to avoid conflicts). New strings may already say "Ensemble".

## Cross-workstream contracts (exact names)

- **Agent identity (X8 defines, everyone uses):** in `Support/AgentIdentity.swift`
  - `extension ConductorCLIID { static func detect(command: String?, title: String?) -> ConductorCLIID? }`
    (matches `claude`, `codex`, `opencode`, `gemini`, `cursor-agent`, `kimi`, `cline`
    as the first word of a command or a terminal title; nil for shells).
  - `struct AgentIconView: View { let cli: ConductorCLIID; var size: CGFloat = 16 }`
    rendering the existing vendor SVG via `ConductorCLIIcons` (popover/SwiftUI
    path; never inside `NSMenu`, where vendor SVGs render 1×1 pt).
  X1 uses it in terminal node headers; X7 in the notch; X8 in tabs, terminal
  panel, palette.
- **Card kinds (X5 defines):** new `CanvasCardContent` cases
  `.mermaid(source: String)`, `.shape(CanvasShape)`, `.stroke(CanvasStroke)`,
  `.text(CanvasText)` (value types in `Canvas/Domain/CanvasWhiteboard.swift`).
  Existing cases stay byte-compatible. X1's card shell renders unknown/new kinds
  through `CanvasWhiteboardCardFace(card:board:)` which X5 provides.
- **Agent actions (X4 defines):** `@MainActor enum CanvasAgentActions` with
  async functions the bridge calls; it uses existing `WorkspaceSession` canvas
  APIs and X5's kinds. Every mutation is undoable and visible.
- **App docking (X6 defines, X4 calls; removed 2026-11-06):**
  `CanvasAppDocking.shared.inspect(cardID:) async -> String?` (Accessibility
  summary of the docked window) and `open(bundleID:in:)`.
- **Ensemble file format (X5):** extension `.rafuensemble` (UTType
  `dev.rafu.ensemble`, conforms to `public.json`), versioned JSON, assets by
  workspace-relative path; opening one from the Files tree opens it as a tab.

## Rules (all workstreams)

1. Read `AGENTS.md`, this file, and the code you change. Base your branch on
   the integration branch: `git checkout -b <branch> claude/rafu-macos-redesign-nqcu7h`
   (worktrees may start on an old commit).
2. No macOS SDK here. Swift 6.2 Linux toolchain: `/opt/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin`.
   Before every commit: `swiftc -parse -swift-version 6 <files>`,
   `swift-format format --in-place` and `swift-format lint --strict` on changed files.
   Test pure logic in a scratch package outside the repo (see
   `docs/references/linux-swift-verification.md`). CI uses **Swift 6.3 on macos-26**.
3. Known compile traps: a `private var x = …` stored property in a struct makes
   its memberwise init private (add an explicit init when other files construct
   it); `_ = x` inside a ViewBuilder must be `let _ = x`; split very long
   modifier chains; avoid mixed `Double`/`CGFloat` arithmetic; macOS 15 APIs only.
4. Visual rules: gold only for focus/selection/live/primary; theme tokens only;
   help + accessibility labels on icon-only controls; Reduce Motion paths.
5. Security: agents act only through an Ensemble that is open in the workspace;
   it need not be on screen. Tools that start a terminal also work with the
   Ensemble in the background (ADR 0026, amendment of 2026-11-12; it
   superseded the 2026-10-22 "still need it shown" rule). Every agent-started
   process appears as a terminal node; per-Ensemble "Agent control" (Off / Ask /
   Allow, default Ask) gates mutating tools; bounded payloads; no secrets or
   message bodies in logs.
6. Commit on `redesign2/<id>-<topic>`. Do not push. Handoff: branch, commits,
   done, skipped (why), edits outside owned paths, tests, compile risks.

## Addendum (2026-10-18): diagrams, icon packs, frames, export — workstream X9

User direction: agents can create diagrams in an Ensemble through Rafu tools;
icon packs for AWS, Google Cloud, Azure and common services (like Eraser.io);
select items and convert them to a **frame**; export to PNG (and more); export
an **animated GIF** where dots travel along arrows to show data flow.

| ID | Model | Workstream | Owns |
|---|---|---|---|
| X9 | Opus | Diagram packs, frames, export | new `Canvas/Diagram/**`, new `Resources/DiagramPacks/` (built-in Common pack manifest only), export commands/menu items it adds via one marked line in the Canvas bar overflow menu |

Contracts (exact names):
- **Model types (X9 defines in `Canvas/Diagram/CanvasDiagramModel.swift`):**
  `CanvasFrame` (title, memberIDs: [CanvasCardID], style token) and
  `CanvasServiceIcon` (packID, iconID, label). Both Codable, Equatable, Sendable.
- **Card kinds (X5 adds the cases):** `.frame(CanvasFrame)` and
  `.serviceIcon(CanvasServiceIcon)` in `CanvasCardContent`, rendered through
  `CanvasDiagramCardFace(card:board:)` (X9 provides). Frames draw behind their
  members; moving a frame moves its members. A frame's rect is derived: after
  every board edit it fits its members (see
  [`canvas-diagrams.md`](../../references/canvas-diagrams.md#frames)).
- **Packs:** built-in **Common** pack drawn with SF Symbols (user, browser,
  mobile, API, server, function, container, database, cache, queue, stream,
  storage, CDN, DNS, load balancer, gateway, auth, monitoring, …). Vendor packs
  (AWS Architecture Icons, Azure Architecture Icons, Google Cloud icons) are not
  redistributed in the repo: "Import Icon Pack…" accepts the official ZIP or
  folder the user downloads (links shown), detects the vendor layout,
  indexes SVG/PNG into Application Support, and searches by name. An optional
  downloader may be added only with a pinned official URL and SHA-256.
- **API for X4 tools:** `@MainActor enum CanvasDiagramService` with
  `searchIcons(query:limit:) -> [CanvasServiceIconMatch]`,
  `createFrame(title:memberIDs:in:session:) -> CanvasCardID?`,
  `export(boardID:target:format:session:) async throws -> URL` where target is
  `.board | .frame(CanvasCardID) | .selection` and format is
  `.png(scale:) | .pdf | .gif(seconds:fps:)`; files go to a workspace folder the
  user can see (default `exports/`), never outside the workspace.
- **Export rendering:** `ImageRenderer` for PNG/PDF; GIF via ImageIO
  (`CGImageDestination`, `UTType.gif`) with frames where a dot travels each edge
  in its direction. Native-view nodes (terminal, web, docked app) render their
  summary face, not live content.

## Addendum 2 (2026-10-18): Now Playing, workspaces, agent hooks, chat history — X10–X12

User direction:
1. Now Playing may use the private MediaRemote framework the way Cider does
   (the BSD-3 `mediaremote-adapter`, run through `/usr/bin/perl`). The public
   path stays as the fallback.
2. Vendor icon packs (AWS, Azure, Google Cloud) get a one-click download (X9).
3. A workspace can hold more than one folder; workspaces can be saved; a view
   lists saved workspaces.
4. Agent hooks, like Cider, track agent activity.
5. Show Claude Code and Codex chat history in Rafu, grouped by project.

| ID | Model | Workstream | Owns |
|---|---|---|---|
| X10 | Opus | Multi-folder and saved workspaces | `Sources/RafuCore/Workspace*` (descriptor, roots), `Sources/RafuApp/Workspace/**`, recents/saved stores, Files tree root handling in `Views/WorkspaceSidebarView.swift` (roots only), new `Views/Workspaces*.swift` (saved workspaces view), the `WindowTitlebarRow` workspace menu, `File` menu commands for Add Folder / Save Workspace, the `.rafuworkspace` UTType |
| X11 | Opus | Agent hooks, activity tracking, Now Playing via MediaRemote | new `Sources/RafuAgentEventHelper/**` (helper executable), new `Sources/RafuApp/AgentTracking/**`, `Notch/NowPlaying*`, `Vendor/MediaRemoteAdapter/**`, hook install UI in the Agents settings pane, `script/build_and_run.sh` + packaging helper staging |
| X12 | Opus | Agent chat history | new `Sources/RafuCore/AgentHistory/**` (read-only parsers), new `Sources/RafuApp/AgentHistory/**` (history tab and navigator entry), one navigator mode case, palette commands |

Contracts:
- **Workspace roots (X10):** `WorkspaceSession.roots: [WorkspaceRoot]`
  (ordered, first is primary); `rootURL` stays and means the primary root, so
  existing callers keep working. Saved workspace file: `.rafuworkspace`
  (UTType `dev.rafu.workspace`, versioned JSON, folder bookmarks + display
  name + window layout reference). Git/search work per root.
- **Agent events (X11):** `AgentActivityStore` (`@MainActor @Observable`,
  one per app) exposes `sessions: [TrackedAgentSession]` keyed by provider and
  session id, with state `working | waitingForPermission | needsInput |
  finished | ended`, `cwd`, last tool, and time. It matches a session to a
  Rafu terminal by cwd + process tree when possible. Notch, titlebar activity
  and Ensemble terminal nodes read it; they keep their output-based fallback.
- **Agent history (X12):** read-only. Claude Code: `~/.claude/projects/*/*.jsonl`.
  Codex: `~/.codex/sessions/**/rollout-*.jsonl` (+ `session_index`). Parsed off
  the main actor, lazily, bounded per file; grouped by project path; "Resume"
  opens a terminal running `claude --resume <id>` / `codex resume <id>` in that
  folder only after the user clicks it (round 4: the CLI is the terminal's own
  process, not a typed line). "Resume in Ensemble" adds a terminal node that
  runs it on the window's Ensemble. Nothing leaves the Mac; nothing is logged.

Security rules for X11: hook installation is an explicit user action with a
review of the exact file and entries; it merges into the provider's config
without removing other hooks, keeps a backup, is reversible, and never runs at
launch. The helper must never block or change the agent's decision (1 s alarm,
exit 0 always, bounded input, private spool directory 0700, files 0600).

## Status (2026-10-18)

- Merged into the integration branch: workstreams X1, X3 to X12, and the R pass.
- Verification: Linux parse + swift-format lint + scratch-package tests; macOS CI (Swift 6.3, macos-26) run via workflow_dispatch — see the PR for the latest result.
- Mac review (2026-10-18): Apple Swift 6.4 / macOS 27.0.1, arm64. Lightning
  built and launched through the canonical script. A separate fixture workspace
  covered Markdown source/preview, board shape creation, Command-Return Mermaid
  editing, PNG export (pixels inspected), editor split menus, narrow-board tools,
  General/Agents/Ensemble Settings, a second folder, and saved-workspace reopen.
- Review fixes: prepare Mermaid pixels before static export; enforce image caps
  even for very large boards; resolve existing ancestors for new export paths;
  place helper scripts/licences in Resources and enforce structured-bundle
  signing; remove an implicit capture warning; expose drawing tools in a compact
  menu when a split cannot fit the full palette; update stale run-based Settings
  copy. See `canvas-diagrams.md`, `agent-hooks-and-now-playing.md`, and
  `build-and-run.md` in `docs/references/`.
- First full Mac test pass: 185 core tests and 2,399 app tests. The export writer
  alias/escape regression was added afterward; repeat format, build, parallel,
  and serial gates before merging. Test logs and final results belong to PR #3.
- Follow-up Mac evidence: live Claude and Codex hook events, Google Cloud icon
  pack download/import, and Calculator docking were checked. Docking fixes
  cover minimum window sizes and permission guidance for the actual app variant.
  See `agent-hooks-and-now-playing.md`, `canvas-diagrams.md`, and
  `canvas-native-boundaries.md` in `docs/references/` for evidence and limits.
- Remaining manual coverage: VoiceOver speech, Cursor hook events (authentication
  blocked the isolated test), and exact multi-display docking placement. UI automation did
  not start native sidebar/tab drag sessions (no source callback was observed);
  do not claim the file-drop or tab-drag path was verified by that pass. Board
  drawing gestures and editor splits through the menu did work.

## Status (2026-10-19)

- Drag to the board: Agent History rows and one-pane Terminal Group tabs can be
  dropped on an Ensemble. A terminal tab moves the live terminal (no restart),
  with a "Move to Ensemble" tab-menu path. Private type
  `dev.vatsalsaglani.rafu.ensemble-drag`, Info.plist index 3. See
  [`canvas-interaction.md`](../../references/canvas-interaction.md) "Board
  drops", [`drag-and-drop-custom-uttype.md`](../../references/drag-and-drop-custom-uttype.md),
  [`agent-history.md`](../../references/agent-history.md), and the ADR 0025
  amendment.
- Hidden editors under the board no longer livelock the main thread when the
  board opens or a terminal card is added
  ([`editor-gutter-ruler-tiling.md`](../../references/editor-gutter-ruler-tiling.md)).
- Verification on main (macOS 27.0.1 (26A434)): lint clean; build clean apart
  from the known SwiftPM "missing creator for mutated node ...
  SwiftTerm_SwiftTerm.bundle" warning; parallel suite 250 + 2522 tests passed;
  `--no-parallel` suite 250 + 2522 passed; `./script/build_and_run.sh
  --verify` exit 0.
- Still open (manual, not provable headlessly): real mouse drags of a History
  row and of a terminal tab (centre versus edge band); whether tab edge-split
  under a visible board was broken since bc795ec and is now fixed; Close never
  selecting a tab.

## Status (2026-10-19, second increment)

Shell choice and card navigation on the board, plus the left-rail removal in the
workbench shell. Owned paths: `Sources/RafuApp/Canvas/` (`CanvasAddMenu.swift`,
`CanvasCommands.swift`, new `CanvasNavigationShortcuts.swift`, new
`Canvas/Integration/CanvasBoardNavigation.swift`),
`Sources/RafuApp/Workspace/WorkspaceSession.swift`,
`Sources/RafuApp/Views/WorkspaceWindowView.swift`,
`Sources/RafuApp/Views/WorkspaceNavigatorView.swift`, and the matching tests.

- Adding a terminal to an Ensemble can now choose a shell (Add popover rows with
  type-ahead, a "Terminal with Shell" submenu, palette commands) and the choice
  persists in the inert saved layout with no process restoration.
- New board-only keys: `Control-Option-1…9` add a terminal with that shell,
  `Control-Command` arrows move card focus spatially, `Control-Command-]`/`[`
  move in reading order. `Command-1…9` stay free.
- The empty left rail beside the Files sidebar is removed in both sidebar
  states.
- References: [`canvas-interaction.md`](../../references/canvas-interaction.md)
  "Shell choice and card navigation",
  [`terminal-signals-and-shell-catalog.md`](../../references/terminal-signals-and-shell-catalog.md)
  "The Ensemble board shares this catalog",
  [`flat-window-chrome-titlebar-merge.md`](../../references/flat-window-chrome-titlebar-merge.md)
  "No left rail"; the ADR 0023 and ADR 0012 amendments of the same date.
- Verification on `main` (Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
  (26A434)): format lint clean; build with 0 new warnings; parallel suite
  250 + 2545 tests passed; `--no-parallel` (CI mode) 250 + 2545 passed;
  `./script/build_and_run.sh --verify` passed for Rafu Lightning.
- Deferred: a shell parameter on the MCP `terminal_create` tool (consent
  surface, ADR 0021 and ADR 0025); per-shell shortcuts for editor Terminal
  Groups; numbered card focus. Known gap:
  `WorkspaceSession.preferredShellStore` is not injectable.
- Open manual checks (none done by a person yet): the shell submenu and
  `Control-Option` keys on a Mac with two or more shells; `Control-Option-2`
  inside an editor Terminal Group reaching the shell; `Control-Command` arrows
  and `Control-Command-]`/`[` from inside a terminal card; whether AppKit routes
  `Control-Command-arrow` to the enabled card item while a disabled pane item
  carries the same key equivalent; arrowing onto a note not entering Edit mode;
  save and reopen keeping the shell name; VoiceOver labels; the window's left
  edge in both sidebar states in light, dark, and Increase Contrast; a second
  window.

## Status (2026-10-19, third increment)

Agent links on every shell the catalog can offer, plus a scrub of inherited
Claude Code session variables. Commits 0c6fbab, e253585, a521f8d. Owned paths:
`Sources/RafuApp/Canvas/Integration/CanvasTerminalBootstrap.swift`,
`Sources/RafuApp/Terminal/TerminalChildEnvironment.swift`,
`Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`, and
`CanvasTerminalBootstrapTests`.

- A fish card previously showed "Disconnected" and had no Rafu MCP tools,
  because only zsh and bash received the bridge environment and the wrapper
  PATH. `CanvasShellBridgeStrategy` now picks a mechanism per shell basename;
  `supportsBridge(shellBasename:)` means guaranteed wrapper PATH order after the
  user's startup files. `BootstrapError.unsupportedShell` is removed, and
  environment-only shells carry a soft notice instead of a failure.
- `TerminalChildEnvironment.scrubbed(_:)` removes an exact list of 11 host
  Claude Code session variables from the bridge environment, because
  `script/build_and_run.sh` launches the app with `open -n`, which passes the
  caller's environment. It is not a prefix rule; user settings such as
  `CLAUDE_CODE_USE_BEDROCK`, `ANTHROPIC_*`, and `CLAUDE_CONFIG_DIR` survive.
- References:
  [`canvas-live-sessions.md`](../../references/canvas-live-sessions.md)
  "Per-shell bridge strategies" and "Host session variables must be scrubbed
  from bridge terminals";
  [`terminal-signals-and-shell-catalog.md`](../../references/terminal-signals-and-shell-catalog.md)
  cross-reference. New decision:
  [ADR 0028](../../decisions/0028-ensemble-bridge-shell-strategies.md).
- Verification on `main` at a521f8d (Apple Swift 6.4 (swiftlang-6.4.0.34.1),
  macOS 27.0.1 (26A434)): format lint clean; build with 0 new warnings;
  parallel suite 250 + 2563 tests passed; `--no-parallel` (CI mode)
  250 + 2563 passed; `./script/build_and_run.sh --verify` launched Rafu
  Lightning. The user confirmed agent links end to end in a fish card before the
  other shells landed; the other shells are not checked by a person yet.
- Open manual checks: for each installed shell, start `claude` in a card,
  confirm `/mcp` lists `rafu`, and confirm the link goes Live; nu, xonsh,
  elvish, and mksh on a Mac that has them (all four are unverified by
  execution); re-check whether the `server:rafu` channel warning is fully
  explained by the inherited variables; the csh `logout` ("Not a login shell")
  and tcsh `~/.cshdirs` limitations of emulated login.

## Status (2026-10-19, fourth increment)

Usage ring cluster, agent status vocabulary, and the drag-and-drop repair plus
drop/source previews. Commits 8262d4e, 6fe806e (usage rings and the restyle
the user asked for); 9c6c095 (merge a257e8d, agent status); 3380c53 (drag/drop
root-cause fixes); 5860a98, 2debd37, 5c72b84 (drop preview, drag preview,
source ghost).

- **Usage rings.** Settings ▸ Usage and the notch Usage section share
  `UsageProviderCardView` → `UsageRingClusterView` over the new shared
  primitive `Sources/RafuApp/Support/RafuProgressRing.swift`: up to three
  concentric arcs, further windows legend-only, stable hue per ring index,
  warnings never recolour an arc, one warning triangle per window.
- **Agent status.** Seven states with a fixed precedence on agent terminal
  cards, a header pill, and the `CanvasAgentSummaryBar` board rollup with jump
  menus. Failed comes only from a reported hook/CLI failure, so a Codex card
  can never show Failed. No cost, no sub-agent count, no tab badge; read/unread
  is session-scoped.
- **Drag and drop.** Files-tree drags no longer land in the text view;
  dropping an already-open file selects its tab; a cancelled board drag no
  longer poisons the rest of the drag; note cards no longer swallow board
  drops; Terminals-panel rows can drag a parked group with the new
  `.terminalGroup(id:)` payload; stopped cards no longer claim "Terminal view
  is not attached"; placement labels have one precedence; an orphaned card
  offers "Start Terminal Here". Drops and drag sources now preview: projected
  ghost card, edge band, whole-board highlight, editor split overlay labels,
  and a `RafuDragPreviewLabel` on all seven internal sources, with the source
  row/tab dimmed in flight.
- **New decision:**
  [ADR 0029](../../decisions/0029-agent-status-vocabulary.md). **Amended:**
  [ADR 0025](../../decisions/0025-workspace-canvas-and-app-previews.md)
  Amendment 2 — the user decided that undo after moving a terminal onto a
  board restores the tab in its source editor group (process keeps running),
  superseding the same date's "undo removes only the card" clause.
- **References updated:**
  [`usage-rings-and-pace.md`](../../references/usage-rings-and-pace.md)
  ("Activity-style ring cluster", the `Date.FormatStyle` time-zone nuance),
  [`nonisolated-extension-isolation-trap.md`](../../references/nonisolated-extension-isolation-trap.md)
  (addendum: a `static func` on a `View` struct needs `nonisolated` too),
  [`agent-hooks-and-now-playing.md`](../../references/agent-hooks-and-now-playing.md)
  ("Agent card status vocabulary"),
  [`canvas-interaction.md`](../../references/canvas-interaction.md)
  ("Agent status on the board", "Board drop previews, labels, and undo"),
  [`drag-and-drop-custom-uttype.md`](../../references/drag-and-drop-custom-uttype.md)
  ("Previews, hover fidelity, and drag end"),
  [`agent-history.md`](../../references/agent-history.md).
- **Gates on `main` at ba00643** (Apple Swift 6.4 (swiftlang-6.4.0.34.1),
  macOS 27.0.1 (26A434)): format lint clean; build with 0 warnings, test
  targets included; parallel suite 250 + 2631 tests passed; `--no-parallel`
  (CI mode) 250 + 2631 passed; `./script/build_and_run.sh --verify` launched
  Rafu Lightning.
- **Known unverified:** whether the local `NSEvent` monitor sees `leftMouseUp`
  during an `NSDraggingSession` nested event loop. If it does not, the source
  dim lasts until the 12 s fallback; the designed fallback is a real
  `NSDraggingSource` with `draggingSession(_:endedAt:operation:)`.
- **Open manual checks, none done by a person yet:** a real-mouse drag of each
  source onto each target; the source ghost clears on drop and on Escape;
  undo and redo of a terminal move; every placement label; the notch ring
  cluster in Indigo and Khadi, a 1–2 % window as a round-cap dot, and a
  six-window Claude snapshot; the agent pills, the Reduce Motion static arc,
  and the board summary bar jump menus.

## Status (2026-10-20, fifth increment)

The Ensemble bar and Terminal Group cards, merged as b107a66 (47420d5,
d1c160a, 40d5c72).

- **List mode removed.** The board has one presentation. `⌃⌘1` and `⌃⌘2` are
  free again. Its accessible purpose is served by a VoiceOver **"Cards" rotor**
  via `accessibilityRotorEntry`, whose `prepare:` both selects and reveals the
  card — a rotor destination off-viewport is otherwise unreachable.
- **One Add palette.** `CanvasAddPopover` serves the bar `+` (`boardPoint` nil),
  the empty-board double-click, and type-ahead: a `LazyVGrid` of tiles with a
  Service Icon tile and shell chips carrying `⌃⌥n` hints, over the pure
  `CanvasAddPaletteNavigation`.
- **The `⋯` overflow menu is retired**, contents redistributed: Export is its
  own button, the link controls moved into the link popover as a
  `RafuSegmentedPicker`, Select All Cards moved to the menu bar, and the Icon
  Library is reached through the palette.
- **Card title** is one `Text` with a `TabClickIntent` double-click rename plus
  a separate `▾` `Menu`. A borderless SwiftUI `Menu` opens on mouse-down, so a
  double-click on a menu label is impossible; the user accepted keeping them
  separate.
- **Terminal Group cards** lost the accordion and `expandedGroupIDs`: pane chips
  in a flow `Layout`, an `AgentStatusPill`, a hover/focus `⋯` backed by the
  context menu, and a Start Agent card row.
  `CanvasBoardState.ensembleSymbol` is `circle.hexagongrid`.
- **References updated:**
  [`canvas-interaction.md`](../../references/canvas-interaction.md)
  ("2026-10-20: one Add palette, no List mode, no ⋯ overflow"). No ADR was
  needed: this is a presentation narrowing inside the accepted board contract.
- **Gates on `main` at 716370a** (Apple Swift 6.4 (swiftlang-6.4.0.34.1),
  macOS 27.0.1 (26A434)): format lint clean; build OK; parallel suite
  250 + 2719 tests passed; `--no-parallel` (CI mode) 250 + 2719 passed;
  `./script/build_and_run.sh --verify` launched Rafu Lightning.
- **Open manual checks, none done by a person yet:** the VoiceOver Cards rotor
  reaching an off-viewport card; the Add palette from all three entry points
  and its type-ahead; every redistributed `⋯` item; inline rename next to the
  `▾` menu; a Terminal Group card's pane chips with enough panes to wrap, the
  status pill, and Start Agent; the `circle.hexagongrid` icon in Indigo and
  Khadi.

## Status (2026-10-20, edge layering fix)

- **Every edge draws below every card**, the hovered and selected edge
  included. `CanvasEdgeOverlay` had redrawn the hovered edge above all cards,
  so a pointer on an edge's visible part painted the whole curve over the
  cards between its ends. `CanvasEdgeLayer` now draws the hover weight, the
  selection halo, the arrowheads and the port stubs; the overlay keeps only the
  drag previews, the selected edge's end handles (hidden where another card
  covers the port) and the popovers. A disappearing edge view clears a stale
  `hoveredConnectionID`.
- **Reference updated:**
  [`canvas-interaction.md`](../../references/canvas-interaction.md)
  ("2026-10-20: every edge draws below every card"). No ADR: a presentation
  rule inside the accepted board contract; it supersedes review 7.6 Layering.
- **Tests:** `Tests/RafuAppTests/Canvas/CanvasEdgeLayeringTests.swift`.
- **Open manual check:** the steps listed in that reference section.

## Status (2026-10-22, link resilience and Codex rebind)

- **The MCP stdio bridge stays alive through a lost launcher link.** It ends
  only on stdin EOF, a poll error, an oversized frame, an encode failure, or an
  output write failure. Reconnect backoff is 300 ms doubled to a 5 000 ms cap
  (heartbeat only). Tool calls during an outage return an `isError` reply. One
  deduplicated stderr line per state change, at most 200 bytes, with no token,
  path, thread, or message text. New optional `CanvasBridgeResponse.code`
  (`"unregistered"`) triggers re-registration.
- **Suspension is route-scoped and Codex can rebind.** A new `release`
  operation clears the route after the visible TUI exits; a `bind` from a new
  supervisor endpoint replaces a dead, stale, released, or suspended route, and
  is refused while a live agent holds it. `unregister` works while suspended.
  Root cause: the proxy revoked with `.transportLost` on a normal Ctrl-D, and
  suspension was permanent.
- **Agents can change an Ensemble that is open but not on screen.** The guard
  is now board identity in the workspace. Tools that start a process or dock an
  app still need the Ensemble shown.
- **App Nap:** a `ProcessInfo` activity with
  `.userInitiatedAllowingIdleSystemSleep` is held only while a terminal has a
  live, non-suspended agent route. It never blocks idle system or display
  sleep.
- **Docs:** new
  [`ensemble-bridge-resilience.md`](../../references/ensemble-bridge-resilience.md);
  [`canvas-live-sessions.md`](../../references/canvas-live-sessions.md) updated
  for route-scoped suspension and off-screen edits; ADR 0026 amended
  (2026-10-22) by the user's explicit direction.
- **Tests:** on `main` after the merge (`aa7e782`), the parallel suite and the
  `--no-parallel` (CI mode) suite both passed with 262 RafuCore tests and 2860
  RafuApp tests.
- **Open checks:** live behaviour overnight, with the screensaver running, and
  after a real Ctrl-D is not yet verified. The exact overnight trigger of the
  old Codex "Disconnected from this task" text stays unknown.

## Status (2026-10-25, X4 agent terminal start and send; X5 Mermaid scale)

Workstream X4 (agent orchestration MCP tools), plus one X5 raster-cap change.
Seven reported bugs addressed.

- **A start no longer reports `ok` when nothing started.** New
  `Canvas/Integration/CanvasTerminalStarter.swift` queues the line, refuses
  early with a named reason (4-terminal lease cap, `startAvailability`), reveals
  the node (pan at live zoom, zoom in below it, and the result says the view
  moved), sets `terminalStartRequest` only when it is free or already this
  card, waits at most 2.5 s re-asking at most 3 times, and reports `running` or
  `stopped` in `ensemble_describe`'s words. A process still starts only through
  the card's own view (ADR 0023, ADR 0025 preserved).
- **A `terminal_send` right after `terminal_start` is no longer lost.** Root
  cause was "pane live ≠ process running ≠ shell ready", not re-entrancy. An
  ordered per-node queue (8 lines, 15-minute expiry, not observed, not
  persisted, not logged) drains once the process runs plus a 500 ms settle,
  bounded at about 10 s, one drain per node; bridge terminals skip the settle.
  `CanvasTerminalCard` drains on `.task(id: pane.sessionID)`.
- **Command and prompt bounds are explicit:** 32 arguments, 1,024 bytes each,
  4,096 bytes per quoted line, prompt 1,024 bytes, `terminal_send` text 4,096
  bytes. Refusal reasons carry counts only, and `terminal_create` validates
  before it creates, so a refusal leaves no node.
- **Mermaid:** `minimumScale` 0.25 (`clampedScale` no longer floors at 1.0) and
  `maxPointArea` 64 M pt² (8000×8000 pt), with `maxRasterPixels` unchanged at
  4 M. No `WKWebView`, and no per-node full-size/Export action in this change.
- **Docs:** new
  [`ensemble-agent-terminal-tools.md`](../../references/ensemble-agent-terminal-tools.md);
  ADR 0020 amended (2026-10-25);
  [`mermaid-native-preview.md`](../../references/mermaid-native-preview.md),
  [`memory-caps-and-pressure.md`](../../references/memory-caps-and-pressure.md)
  and [`canvas-live-sessions.md`](../../references/canvas-live-sessions.md)
  updated.
- **Verification:** `./script/format.sh --lint` clean; `./script/build.sh` 0
  source warnings; `./script/test.sh` 2,885 tests in 203 suites passed (16.1 s);
  `./script/test.sh --no-parallel` 2,885 tests passed (47.4 s);
  `./script/build_and_run.sh --verify` exit 0.
- **Open checks — a live MCP pass inside Rafu Lightning is outstanding:** an
  off-screen or zoomed-out create, `terminal_start` then an immediate
  `terminal_send`, the 500 ms settle against heavy rc files, the 4-terminal
  lease cap, Ask mode, the 17-table `erDiagram` by eye, the
  `.task(id: pane.sessionID)` drain, and the refused-start alert path. The
  Mermaid caps also still await a measured Release idle pass.

## Status (2026-11-01, clustering Tidy Up and the attention record)

Uncommitted on `main` at the time of writing.

- **Tidy Up clusters instead of flowing rows.** New pure, deterministic
  `Canvas/Domain/CanvasClusterLayout.swift`: rigid frame units (a frame with
  members is never emitted; members move by one integer translation), loose
  drawings attached within 120 pt, link-connected clusters laid out hub-and-rays
  with a ≤80-sweep separation pass and a never-overlapping shelf fallback, and
  shelf packing shaped by the viewport aspect. The old grid
  (`CanvasLayoutMath.tidy`/`tidyGap`) is removed and no grid mode is kept;
  `fitAll()` runs after the single `edit` (one undo step, one save).
  `CanvasCardContent.isWhiteboardDrawing` was added to classify drawings.
- **Per-card attention record.** New `Canvas/Domain/CanvasNodeAttention.swift`
  (record, decay, merge, prune, caps as an `extension CanvasLimits`,
  `CanvasAttentionClock`), fed only by coarse focus transitions, with a 7-day
  half-life and a workspace-local `ensemble-attention.json` sidecar
  (atomic 0600, fail-soft, durations and dates only, nothing logged) handled in
  `CanvasPersistenceStore`; flush and lifecycle hooks in `CanvasBoardState`,
  `WorkspaceCanvasStore`, `WorkspaceCanvasActions`, `WorkspaceCanvasView`.
- **New decision:**
  [ADR 0032](../../decisions/0032-ensemble-clustering-tidy-and-attention-record.md)
  (owner decision: a persisted sidecar over topology-only or session-only
  attention; relates to ADR 0025 and ADR 0023).
- **New reference:**
  [`ensemble-clustering-tidy.md`](../../references/ensemble-clustering-tidy.md).
- **Tests:** new `Tests/RafuAppTests/Canvas/CanvasClusterLayoutTests.swift`
  (14 layout + 2 board tests, including that 640 × 420 pt terminals no longer
  tidy into a 2-wide column) and
  `Tests/RafuAppTests/Canvas/CanvasNodeAttentionTests.swift` (20 tests). The old
  `tidy` test was removed from `CanvasLayoutMathTests.swift`.
- **Verification** (Swift 6.2 language mode, macOS Darwin 27.0.0, 2026-11-01):
  format lint clean; build clean apart from the known SwiftTerm bundle "missing
  creator" notice; parallel suite 2,931 tests in 210 suites + 278 in 16 passed
  (re-run after the search-palette change, so it describes the final tree);
  `./script/build_and_run.sh --verify` exit 0. No `--no-parallel` (CI mode) run
  is recorded for this increment.
- **Open manual checks, none done by a person yet:** Tidy Up on a real board;
  undo of a Tidy; zoom-to-fit with Reduce Motion; the sidecar file on disk;
  cluster spacing with 640 × 420 pt terminals at 16:10; the quit-path
  `flushAll`.

## Status (2026-11-12, Allow answers Claude's channel dialog by itself)

User direction: on Allow, Rafu selects "yes" to Claude's development-channel
dialog without waiting, in the Ensemble and in Voice. ADR 0026 amendment
2026-11-12; evidence in `docs/references/canvas-live-sessions.md`, "2026-11-12:
why Allow still waited".

- Delivered: the watch starts at every recorded launch and reads the Agent
  control, the setting, and the board at every sample (a switch to Allow after
  the start answers a waiting dialog); the matcher no longer needs the words
  "Enter to confirm" in the footer, only the dialog as the tail of the screen;
  Claude's folder-trust dialog extends the window (cap 600 s) and is never
  answered; the `ChannelPrompt` log lines are `notice` level; fixtures follow
  the `DevChannelsDialog` source read from Claude Code 2.1.322.
- Voice: no code path of its own. A Voice-started Claude is a normal board
  terminal; the board's Allow and the existing Settings ▸ Ensemble toggle apply.
- Owned paths: `Sources/RafuCore/CanvasBridge/CanvasChannelPrompt.swift`,
  `Sources/RafuApp/Canvas/Integration/CanvasChannelPromptConfirmer.swift`, and
  `CanvasLiveBridge.recordClaudeLaunch` (one new test seam, `terminalIO`).
- Open: no live run on Claude Code 2.1.322 yet (the footer words were not
  read from a screen). A Claude killed without `unregister` and restarted
  within 15 s is not watched (logged).
- Manual checks (the user; Rafu Lightning only): Allow with the board visible;
  Allow with the board on another tab; Allow with a slow folder-trust answer;
  start in Ask, then switch to Allow; Voice "start a Claude session" on an Allow
  board; Ask must still wait for you. Read the `ChannelPrompt` log lines if one
  fails.

## Status (2026-11-12, background agent starts and held messages)

Two reported bugs: an agent-started peer sometimes waited for the user to press
Start, and a message sent to a peer that was still starting turned the link
Failed.

- **Agent starts no longer need a card view.** Root cause: a shell spawns only
  after a terminal view exists, and only a mounted card created it. With the
  Ensemble on another tab the tool refused ("Show this Ensemble ..."); with the
  window occluded the card consumed `terminalStartRequest` and silently did not
  start. Now `CanvasTerminalStarter` starts the pane itself and creates the
  view unmounted when no card can host it (`startTerminalPane(_, background:)`,
  `hostCanvasTerminalView`). No lease, no reveal, no focus. A card re-takes its
  lease when the window is visible again. `needsShownBoard` and
  `notShownMessage` are removed. ADR 0026 amended.
- **Messages to a starting peer are held, not failed.** `CanvasLiveBridge` holds
  up to 8 messages per target for 2 minutes and delivers them in order when the
  peer registers, when the Codex `bind` supplies the thread, or on a heartbeat.
  A Codex queue refusal within 45 s of connecting is retried every 3 s. Failed
  keeps meaning a real failure (expiry, refusal after the grace, full inbox,
  send limit). Agent guidance (MCP instructions, tool descriptions,
  `rafu-ensemble` skill and references) says: start, wait until
  `list_connections` shows `connected`, then send.
- **Docs:** [`canvas-live-sessions.md`](../../references/canvas-live-sessions.md)
  (two new sections),
  [`ensemble-agent-terminal-tools.md`](../../references/ensemble-agent-terminal-tools.md)
  section 2, ADR 0026 amendment. No new reference note and no row in
  `docs/references/README.md`.
- **Open checks, all live (the user; Rafu Lightning only; no synthetic input):**
  - [ ] Claude to Codex, Codex to Claude and Claude to Claude: `terminal_create`
        with `agent`, `prompt` and `link: true` while another editor tab is
        selected. The node starts, its line types, the edge reaches Live, no
        click.
  - [ ] The same with the window minimized or hidden behind another app.
  - [ ] A second message right after the start says Held, arrives after the
        peer connects, and the edge never shows Failed.
  - [ ] Show the Ensemble afterwards: the cards attach to the running shells
        (no "Terminal view is not attached"), and the shell is resized.
  - [ ] Whether Claude Code's first turn can already call Rafu tools before its
        MCP server connects (the prompt is a launch argument).

## Generated views (wave 3)

Status (2026-11-08): wave 3 of the swift-json-render integration is merged on
`main` (09faf7d) except the fix round on branch `fix/voice-mic-allow`, which is
not merged when this section was written. Docs written on `docs/wave3`. No manual
check below has been done by a person.

- **Decision:** [ADR 0036](../../decisions/0036-generated-views-on-the-ensemble-board.md);
  amendments to ADRs 0034, 0035, 0026 and 0028.
- **References:**
  [`generated-view-card-and-state.md`](../../references/generated-view-card-and-state.md),
  [`remote-image-consent-and-trust.md`](../../references/remote-image-consent-and-trust.md),
  [`view-tools-and-vocabulary.md`](../../references/view-tools-and-vocabulary.md),
  [`voice-delta-streaming.md`](../../references/voice-delta-streaming.md),
  [`mdx-preview.md`](../../references/mdx-preview.md),
  [`swift-6-4-2-catalog-registration-traps.md`](../../references/swift-6-4-2-catalog-registration-traps.md).
- **Delivered (by area):**
  - Card and state: `Canvas/GeneratedView/**`, `Tests/RafuAppTests/GeneratedView/**`;
    touch points in `CanvasCardViews`, `CanvasCardChrome`, `CanvasCommands`,
    `CanvasDiagramExportView`, `CanvasAgentActions` (+ `CanvasAgentActions+Views`).
  - Images: `Canvas/RemoteImages/**`, `Settings/ImageTrustSettingsSection.swift`,
    `Resources/PublicSuffix/`, `Tests/RafuAppTests/RemoteImages/**`.
  - Tools: `RafuCore/CanvasBridge/CanvasAgentViewVocabulary.swift`, the MCP
    `instructions` sentence, `Voice/VoiceToolExecutor+Views.swift`,
    `Resources/AgentSkills/rafu-view/`, the two-skill installer.
  - MDX: `Markdown/MDX*.swift`, `Components/Document/**`, `Tests/RafuAppTests/MDX*`.
  - Contract commit: `Package.swift` (git URL, exact tag, `RafuApp` only),
    `CanvasDocument` (`generatedView` case, `permissions`), view tools in
    `CanvasAgentTools.swift`.
- **Fix round (branch `fix/voice-mic-allow`, not merged):** stream undo collapse
  also checks `board.changeStamp`; the orphan rule uses `ArgumentStream.finished`;
  the MDX and card themes come from `GeneratedViewThemeCache`; `Task.isCancelled`
  is checked after `apply` in `GeneratedViewCardModel`; Settings ▸ Voice gets
  "Allow Microphone…"; the package pin moves to `0.22.0-alpha.2`.
- **Exit status:** code and unit tests are in; gate results (test counts per mode,
  `build_and_run.sh --verify`) were not part of the documentation handoff and are
  not recorded here. Open follow-ups: narrow `Figure` roots for documents; report
  the voice "deltas: N" value; undo of a consent grant does not bump the image
  provider revision (cosmetic); the cold-build cost of `swift-syntax` is not
  recorded.
- **Manual checks (the user; Rafu Lightning only; no synthetic input). None done.**
  - [ ] Voice: Ask, Off, an interrupt, and a card rename during the stream.
  - [ ] MCP Ask from Claude Code and MCP Allow from Codex, with a `view_update`
        patch and a reset.
  - [ ] State persists across relaunch; Reset View from the header menu, the
        context menu and ⌥⌘R, and Undo; the saved file has no `_draft` and no
        password value.
  - [ ] Images: placeholder, consent card, load; trust list in Settings; revoke in
        two Ensembles; `*.com` refused; the consent card offers only the exact
        host for `raw.githubusercontent.com` (`githubusercontent.com` is a public
        suffix); keyboard and VoiceOver.
  - [ ] MDX wireframes in Indigo, Khadi and Increase Contrast; unknown component
        fallback; Stat and Compare.
  - [ ] A second window shows the same view card (state is last write wins).
  - [ ] PNG export draws the card.
  - [ ] Install for Claude Code writes `rafu-ensemble`, `rafu-view` and
        `json-render-swift-use` (the third added 2026-11-15); the conflict prompt.
  - [ ] Memory with the 20-view fixture: under 40 MB above empty, under 2 MB per
        idle card.
  - [ ] Microphone: press "Allow Microphone…", then Rafu Lightning appears under
        Privacy ▸ Microphone.

## Status (2026-11-15, agents find the view skills and the item shapes)

Commit `f31d079`, merged by `6f428e6`. User report: a Codex agent could not find the
skill that the `view_render` description named, so it read Rafu's Swift sources to
learn prop shapes. Decision: ADR 0036 Amendment (2026-11-15). Details:
`docs/references/view-tools-and-vocabulary.md` "Three skills, one install".

- **Third bundled skill.** `json-render-swift-use` (upstream 0.22.0-alpha.3, commit
  `a319217c950cc55de0b31f884e8c32877e2b09ee`; LICENSE and NOTICE unchanged) joins
  `ConductorBundledSkillCatalog.skills`.
- **Item shapes.** New `rafu-view/references/components.md`: exact props and one
  validated example for each of the 17 components. `rafu-view` SKILL.md and the
  `view_render` description name both skills. The vocabulary text is 6134 of 6144
  bytes.
- **Fix.** `examples.md` Stat intent `success` is now `good`.
- **Tests.** New `AgentSkillBundleTests` (8 tests). Parallel mode: 523 tests in 40
  suites and 3901 tests in 318 suites passed. No `--no-parallel` result recorded.
- **Install is manual.** Skills install only on Install in Settings > Ensemble; no
  refresh on launch. The coordinator copied the new files into `~/.claude/skills`
  and `~/.codex/skills` for this user.
- **Open check (manual, Rafu Lightning):** a fresh Codex or Claude Code agent
  renders a view from the skills alone, without reading Rafu source.

## Status (2026-11-12, silent agent close and no Ensemble terminal limit)

Two user-reported issues. Details: `docs/references/ensemble-agent-terminal-tools.md`
sections 9 and 11; ADR 0024 Amendment 1; ADR 0023 and ADR 0025 notes.

- **An agent's `node_remove` on a terminal is silent.** It stops the process,
  closes the group, and removes the node and its edges with no "Close Terminal
  Group?" sheet, no alert and no notice (`removeCanvasTerminalCardForAgent`). The
  Agent control approval (Ask) is unchanged and is the only prompt. Undo restores
  the node, not its process. A user's own close keeps its confirmation.
- **No limit on Ensemble terminals.** Ensemble groups are exempt from the 20-group,
  200-retained-pane and 200-live-session bounds; the four-lease presentation cap
  and the `leaseCap` start hold are deleted; a saved board restores up to
  `CanvasLimits.cards` terminal groups. Terminal Group editor tabs keep every
  ADR 0023 and ADR 0024 bound. `CanvasLimits.cards` (100) and `connections` (200)
  stay as document bounds for every node kind.
- **Open checks (manual, in Rafu Lightning):** an agent closes a running Claude
  terminal in Allow and in Ask; five or more live Ensemble terminals at once;
  relaunch with more than 20 terminal cards; Edit > Undo after an agent close.

## Status (2026-11-15, Codex relay keeps listening and resumes the link after a reconnect)

User report: Codex in an Ensemble terminal showed "Reconnecting to server…", then
"Automatic reconnect timed out … Reconnect failed". Commits `b949dda` and
`2e47ddd`, merge `621a96a`. Decision: ADR 0026 Amendment (2026-11-15). Details:
`docs/references/ensemble-bridge-resilience.md`, "Codex relay reconnect".

- **Cause.** The relay cancelled its listener on the first accept (the TUI's
  reconnect got `ECONNREFUSED`), one IO failure ended both workers, and nothing
  resumed the link after `suspend(transportLost)`.
- **Delivered.** Listener lives for the supervisor run; per-connection state;
  newest connection wins; link states live / lostInTransport / sessionChanged;
  new bridge operation `resume`; exit line from the outcome; cause
  `terminalClosed`; a masked close frame from `CanvasCodexRPC.deinit`; the relay
  strips `x-codex-app-server-compression` and `Sec-WebSocket-Extensions`.
- **Tests.** Five relay tests (the reconnect test fails on the old code with
  `ECONNREFUSED`; the large-notification test also passes on old code), plus
  `CanvasLiveBridgeTests` resume rules. Parallel on the branch before `2e47ddd`:
  528 tests in 40 suites and 3895 in 317. Main gates, parallel and
  `--no-parallel`: 529 tests in 40 suites and 3903 tests in 318 suites passed in each mode; `build_and_run.sh --verify` passed (Apple Swift 6.4.2, macOS 27.2).
- **Open.** The drop trigger is unproven (compression negotiation, now removed;
  the 10 s write and frame deadlines). Not proven that codex-cli 0.169.0 sends
  `thread/resume` after a reconnect; if not, the link is live again at the next
  request with the bound `threadId`. Manual check in Rafu Lightning: drop the
  Codex connection and confirm the TUI reconnects and the link shows live.

## Status (2026-11-15, a user add starts the shell; the lease follows the card; wheel scroll in cards)

Three user-reported defects, fixed in commits `7a22232` (terminals) and `7ffab02`
(scroll), merged by `d0e5499` and `27805d4`. Decision: ADR 0025 Amendment 5.
Details: `docs/references/ensemble-agent-terminal-tools.md` section 9 and
`docs/references/canvas-interaction.md` "Scroll routing".

- **A user add starts the shell.** Add menu, `T`, seed, ⌃⌥1–9, palette, chosen
  shell, Connect to new terminal, Duplicate and Start Terminal Here call
  `addCanvasTerminal` or `startCanvasTerminalCard`. Foreground (board shown, zoom
  at least 50 %, board is the selected tab of the focused editor group): claim
  the lease and focus. Otherwise a background start: select, no view move, no
  editor tab. Duplicate and Connect start after the final rect and edge.
- **The lease follows the card.** No release in `onDisappear`; a mounted card
  claims a free lease at once. Placeholder "Show Here" only for an editor tab or
  another Ensemble. A focused terminal stays live down to 25 % zoom. Reveal goes
  to the card (`revealTerminalGroupWhereItLives`). The Terminals panel and tab
  switcher show "On an Ensemble". A board reload re-presents its resources.
- **Wheel and trackpad scroll reaches card content.** `CanvasScrollRouter`
  (`Canvas/Domain/CanvasScrollRouting.swift`) replaces `capturesScroll`.
  `.scrollDisabled` is gone from `CanvasMarkdownFileCard`.
- **Tests.** `CanvasTerminalAddStartTests`, `CanvasTerminalLeaseTests`,
  `CanvasScrollRouterTests`. Parallel runs in the worktrees: units 1+2, 443 + 3586
  passed; unit 3, 3582 passed (19 router tests added). On `main`: parallel and
  serial suites pass on main: 443 + 3605 tests in each mode.
- **Test nuance.** A test that uses any user terminal add path
  (`addCanvasTerminal`, Duplicate, Start Terminal Here, Connect) must set
  `spawnsHeadlessCanvasTerminals = false`, or it starts a real shell.
- **Open checks (manual, in Rafu Lightning; the user's device check is pending):**
  add a terminal at 100 % and see a shell with keyboard focus and no click;
  add at 40 % zoom and see the shell start without a view move; zoom out and in,
  scroll a terminal off screen and back, and resize a card, with no placeholder;
  Transfer Here shows "Show Here" and the button moves the view back; scroll a
  Markdown or MDX card with the wheel and the trackpad without a click, and
  see the board pan once the card reaches its end on the next gesture; ⌘-scroll
  zooms over a card; Space or Hand tool pans over a card; wheel pan speed.
- **Unverified (code-read or headless only):** keyboard focus at mount;
  readability of a focused terminal at 25–50 %; ⌃` on a focused card terminal
  seems to do nothing now (the card reclaims the lease); ⌃` with nothing selected
  can still reveal a parked group as an editor tab; the Terminals panel may update
  late (`canvasResources` is not observed); undo of an add leaves a parked running
  shell; two cards for one group are both live (older behaviour); the board
  reload re-present (D6) was not confirmed in the app; the hit test into a
  SwiftUI `ScrollView` on the scaled board, content insets, hidden editor views
  under the board, momentum delivery, and wheel pan speed in the live app.

## Status (2026-11-19, Ensembles panel in the sidebar activity rail)

User request: add the Ensemble to the left sidebar like Files and Git. Commit
`721c8c5`, merge `411c450`. Decision: ADR 0002 note 2026-11-19. Details:
`docs/references/sidebar-panel-anatomy-and-terminal-rows.md`, "Ensembles panel".

- **Delivered.** A sixth navigator mode, `.ensemble`, between Terminals and
  History. The panel lists saved and open Ensembles (file-bound boards too) and,
  when an Ensemble tab is selected, its nodes. Open, Rename…, Duplicate, Close and
  Delete Saved Ensemble… use existing store and session APIs. Delete uses the new
  `CanvasDialog.deleteSaved`. ⇧⌘E "Show Ensembles" in the View menu and the
  palette. No new store, format, task or process.
- **Not in v1.** Rail attention badge, drag from the panel to a board, inline
  rename, per-board disclosure.
- **Tests.** `CanvasNavigatorModelTests`, `CanvasNavigatorPanelContractTests`.
  `ConductorSettingsTests` (allCases count 5 to 6) changed with coordinator
  approval. On `main` 411c450: `./script/test.sh` (parallel) and
  `./script/test.sh --no-parallel` both passed, 3959 tests in 324 suites in each
  mode.
- **Open checks (manual, in Rafu Lightning; no GUI run yet):** a live "Needs input"
  glyph update on a terminal node row; keyboard (arrows, Return, Space);
  VoiceOver; a second window (a board made there appears after Refresh); relaunch
  restores the mode; Increase Contrast and the frosted base.

## Status (2026-11-20, answer agent requests from the Up next row)

User request: answer an agent's approval request from the Up next row. Merged on `main` (last merge:
"Up next approval rows"). Decision:
[`0042-answer-agent-requests-from-up-next.md`](../../decisions/0042-answer-agent-requests-from-up-next.md).
Details: [`codex-app-server-approvals.md`](../../references/codex-app-server-approvals.md),
[`claude-permission-request-hook.md`](../../references/claude-permission-request-hook.md),
[`notch-companion.md`](../../references/notch-companion.md) rule 19.

- **Delivered.** One shared request contract (`CanvasAgentRequest`, `AgentRequestStore`, bridge operations
  `approvalOpen`, `approvalPoll`, `approvalClose`). Codex: the proxy answers on the terminal UI's own connection
  (commands, permissions, questions with listed choices). Claude Code: a separate blocking
  `PermissionRequest` hook entry (helper `--answer`) for Bash, Edit, MultiEdit and Write; Settings > Agents
  "Answers from Up next" switch (off by default) and an "Answer hook" Connect and Disconnect with a review. Up
  next: "Needs approval" badge, request rows, island card shows the request. The terminal dialog always stays;
  no output means the terminal decides. Claude has no "Allow for this session".
- **Review fixes (2026-11-20).** The command always shows whole (no "Show all"). Terminal-only: every file change
  (Codex and Claude; the row cannot show the change), a command with more than 2 blank lines or 64 spaces in a row,
  a Codex command with `networkApprovalContext`, a Claude Bash request with `dangerouslyDisableSandbox`, and text
  with Unicode format characters. Clicks on answer buttons are ignored for 0.5 s after the rows change. A pinned
  panel takes key status for request rows only after a click or pointer movement over them. Live check: a late
  hook allow after a terminal "No" is not obeyed (Claude Code 2.1.329).
- **Not built, decided.** Claude Code `AskUserQuestion` questions stay terminal-only: a blocking `PreToolUse` hook
  hides the terminal question while it waits (spike, Claude Code 2.1.329). Revisit when a Claude Code version
  shows the question while the hook waits.
- **Tests.** On `main`, parallel and `--no-parallel` both passed (the coordinator reported "4040 + 634 tests"; the
  handoff did not split the counts by mode or test target). Claude install step: unit tests only; no live probe of the full app path.
- **Open checks (manual, in Rafu Lightning; no GUI run yet):** answer from the row and answer from the terminal;
  a stale click (message "This request was already answered."); keyboard on a pinned panel; VoiceOver for the
  badge, row and island card; contrast; a second window; island card expansion and the return to Usage; the
  Settings switch and the Connect review (and Disconnect) for the Answer hook. Also not verified live: a "No"
  in the Claude terminal and its hook event.

## Status (2026-11-21, message replies, honest held messages, pre-approved Rafu tools for Codex)

Decision record about pre-approving Rafu's own tool server for Codex (ADR 0044:
[`0044-pre-approve-rafu-tools-for-codex.md`](../../decisions/0044-pre-approve-rafu-tools-for-codex.md)).
Reference: the section "2026-11-21" of [`canvas-live-sessions.md`](../../references/canvas-live-sessions.md).

- **Delivered (source and unit tests only).** A received message starts with a Rafu line that names the sender
  (`@mention` and peer id) and says how to answer, for Claude and for Codex. Held messages say their real cause (four
  texts), wait 5 minutes (was 2), and `list_connections` shows `pending` and `lastDelivery` (`expired` or `failed`).
  An accepted send to a Codex peer says that an idle Codex needs `terminal_send`. A Codex register without route
  keys keeps the bound route and thread. The Codex launcher adds `mcp_servers.rafu.default_tools_approval_mode="approve"`
  to the terminal's private app server only; the read-only Rafu tools carry `readOnlyHint`. The skill and the MCP
  instructions state the reply rule.
- **Not built, decided.** Up next support for other MCP servers' Codex approvals.
- **Open checks (manual, in Rafu Lightning):** a Codex agent calls `ensemble_describe` and `list_connections` with no
  "Allow the rafu MCP server to run tool" question (if it still asks: try `writes`, then the per-tool
  `approval_mode`); Agent control Ask still raises a Rafu approval for a changing tool and Off refuses it; a child
  Claude answers a coordinator over the channel; a send to a Codex peer right after it starts says "not connected
  yet" or "cannot take messages yet"; an expired message shows `lastDelivery: expired` and a Failed link; a send to an
  idle Codex names `terminal_send`.
