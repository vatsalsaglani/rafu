# Codex full access in Ensemble terminals

Applies to: `Sources/RafuCore/CanvasBridge/CanvasAgentFullAccess.swift` (values, policy, input guards, argument
split), `CanvasAgentTools.swift` (`terminal_create` `access`, the prompt, text and command guards, the
keeps-full-access approval line), `CanvasAgentConfigure.swift` (Codex mode `full`), `CanvasCodexSession.swift` (the
launcher asks the app for its grant), `Sources/RafuApp/Canvas/Integration/CanvasFullAccess.swift` (Settings switch,
badge, row registry, one-time grants), `CanvasLiveBridge.swift` (the `full_access` bridge operation),
`CanvasAgentActions.swift` and `CanvasAgentActions+Configure.swift` (gate, grant, log), `WorkspaceCanvasStore.swift`
(row badge after a reload), `Voice/VoiceToolExecutor.swift` and `VoiceConfirm.swift` (voice gate),
`Settings/EnsembleSettingsTab.swift`, the card header in `Canvas/Views/CanvasCardViews.swift`, and the agent rows in
`Views/NotchSectionViews.swift`.
Decision record: the decision record about full access agents in Ensemble terminals
([ADR 0041](../decisions/0041-full-access-agents-in-ensemble-terminals.md)).

Last verified: Swift 6.4.2, macOS 27, 2026-11-19, codex-cli 0.170.0 (`codex --help`, `codex resume --help`, and
the live probes below).

## Observations

1. **`--remote … resume <id>` refuses permission flags.** Rafu starts Codex as `codex --remote unix://… resume
   <thread> <user arguments>`. With `--dangerously-bypass-approvals-and-sandbox`, and also with
   `-c sandbox_mode="read-only"`, the terminal UI exits at once with "Error: Permission overrides are not supported
   when resuming a remote task." A new remote session (`codex --remote … --dangerously-bypass-…`, no `resume`)
   accepts the flag and shows "permissions: YOLO mode". `--yolo` is a 0.170.0 alias of the bypass flag.
2. **The private app server takes the same meaning as configuration.** `codex app-server --listen … -c
   approval_policy="never" -c sandbox_mode="danger-full-access"`, then a Rafu-style `thread/start` +
   `thread/name/set` and a plain `--remote … resume <thread>`: `/status` shows "Permissions: Full Access". Each
   `codex` start spawns its own server, so the overrides never reach another terminal.
3. **A conversation keeps full access.** A thread that once ran on a full-access server shows "Full Access" again
   when it resumes on a default server, and on a server with `-c sandbox_mode="read-only"`. Server configuration
   only fills in a thread with no stored permissions. Consequences: `agent_configure` mode `full` works (resume on
   a full-access server). A later `read_only` or `workspace_write` change cannot lower it: Rafu types `codex resume
   <id> -c sandbox_mode="…"`. Not verified on the real path: `resume` does not attach to the Rafu launcher (see
   observation 4), so it is a plain local Codex start, not the `--remote … resume` form of observation 1. Treat
   "a later change cannot lower it" as unverified. Rafu never clears the badge. A model-only
   change, an Agent History Resume, or a restart of that conversation also keeps full access, with no new question.
4. **`resume`, `fork`, `exec` and `review` skip the launcher.** `CanvasBridgeLaunch.shouldAttach` returns false for
   these subcommands, and the shim calls the real Codex with the arguments unchanged
   (`Tests/RafuCoreTests/CanvasBridgeLaunchTests.swift` asserts this). So the grant check never runs for them: any
   full-access spelling works with the switch Off and with no badge, for example `codex resume --last --yolo` or
   `codex exec -s danger-full-access -a never "task"`. The user accepted this gap on 2026-11-20 (decision record
   "Full access agents in Ensemble terminals").
5. **Why "Another agent is already connected in this terminal".** Typing `codex …` into a node whose earlier Codex
   still holds the terminal's bridge route is refused by the app. Rafu builds the line itself (`terminal_create`
   `access: full`); agents must not type the flag.

## Rules

- **The boundary is the launcher's grant.** The launcher always removes the bypass flag and `--yolo` from the
  terminal UI's arguments. It then asks the app over the terminal's private token (bridge operation `full_access`).
  The app answers yes only once per approved request for that node (`terminal_create` `access: full`, or an
  `agent_configure` mode `full` that is about to run), within 15 minutes, with the switch on and Agent control not
  Off; the answer consumes the grant. Only then does the server get `serverOverrides`. With no grant the launcher
  prints one stderr line (`noGrantNotice`) and starts the default server. This covers only a new Codex session
  that attaches to the launcher. A flag typed on `codex resume`, `fork`, `exec` or `review` gives full access
  (observation 4, accepted gap).
- Off by default: Settings > Ensemble > "Allow Full access agents" (`ensemble.allowFullAccessAgents`). Off refuses
  every full request with the switch's name, before any question or node, and the activity log says "Blocked:
  Allow Full access agents is off".
- Agent control Off refuses first. Otherwise a full request asks every time, also in Allow; `allowsAlways` is false
  and a voice Confirm offers no session grant (its own `+full` grant key). `perform` checks the switch again, so an
  approval after the user turned it off fails. A queued `agent_configure` checks it again when it runs, and a failed
  run revokes its grant.
- **Guards on agent input (not a boundary).** A `prompt` whose first non-space character is `-` is refused (it
  would be read as an option). `terminal_send` `text` and every `command` element that contains the bypass flag,
  `--yolo` or `danger-full-access` as a substring (also inside `sh -c "…"`) are refused. A `command` can still run
  any program, so these refusals only catch the plain cases; the grant is what stops the rest.
- The card flag (`CanvasCard.fullAccess`) is a badge only and is saved; the launch line and the grant live only in
  memory. A reopened board starts a plain shell. `markFullAccess` adds no undo step and marks the undo and redo
  snapshots too. The Up next and Agents rows read `CanvasFullAccessTerminals` (by terminal group), filled by
  approved requests and, when a board loads, from its node flags; never by reading cards in the row code.
- A change to a node that has the flag shows "Full access: this Codex conversation keeps full access" in the
  question (`keepsFullAccess`), by MCP and by voice.

## Reproduce

The probes are small Python scripts that start `codex app-server` on a private `/tmp/rafu-probe-<uuid>/socket`,
create a thread over the WebSocket JSON-RPC (`initialize`, `thread/start`, `thread/name/set`), start the terminal UI
with `--remote … resume <thread>` in a pty, type `/status`, and read the "Permissions:" line. They start no model
turn. Each run leaves one named, empty session in `~/.codex`.

## Verification

```bash
swift test --filter "FullAccess|fullAccessReachesTheServer|noFlagAsksForNoGrant"
```

Manual: turn the switch on, ask an agent for `terminal_create {"agent":"codex","access":"full"}`, approve, check
that the peer joins the board (`list_connections` connected), that `/status` says Full Access, that a command such
as `swift build` runs without a prompt, and that the node header and the Up next row show "Full access". Then type
`codex --dangerously-bypass-approvals-and-sandbox` by hand in another Ensemble shell: the stderr line appears and
`/status` does not say Full Access. Last, type `codex resume --last --yolo`: it does get full access (the
accepted gap).
