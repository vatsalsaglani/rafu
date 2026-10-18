# Ensemble canvas (round 2)

- Status: Active implementation (user direction, 2026-10-18). Base: `main` at `5e01dca`.
- Integration branch: `claude/rafu-macos-redesign-nqcu7h` (restarted from `main`).
- Earlier spec still applies for visual rules: `macos-redesign.md`,
  `docs/references/macos-redesign-visual-system.md`, `canvas-interaction.md`.
- The user asked to ignore ADR constraints. Do not edit `docs/decisions/`.

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
10. Notch HUD rebuilt like Cider (`/home/user/vatsalsaglani/cider`, same
    author): mascot, now playing, Ensembles and agents, usage.
11. Make it look better.

**Platform fact for item 9:** macOS has no public API to embed another app's
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
| X6 | Opus | Native app docking | `Canvas/Adapters/CanvasNativeAppCard.swift`, `CanvasPreviewLoader.swift`, `CanvasWindowCloseGuard.swift`, new `Canvas/Integration/CanvasAppDocking.swift` |
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
- **App docking (X6 defines, X4 calls):**
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
5. Security: agents act only through the visible Ensemble; every agent-started
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
  members; moving a frame moves its members.
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
