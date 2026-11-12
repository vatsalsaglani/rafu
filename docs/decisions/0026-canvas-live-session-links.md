# ADR 0026: Live session links on Canvas

- Status: Accepted through the user's explicit direction, 2026-10-18.
- Supersedes ADR 0025's restriction that all relationships are visual only.

## Decision

Any two Canvas nodes can have a relationship. A new link between terminal nodes
permits messages in both directions between their live Claude Code or Codex
sessions. Other node types remain labeled relationships; a file, app, or shell
is not an agent message endpoint. No file text or app capture is sent by a link.

There is no separate Agent card, task form, role selection, or Start Run action.
The user starts a normal Canvas terminal and types `claude` or `codex`. Private
shell startup files add wrappers for these commands without changing the user's
shell configuration. The wrappers preserve the visible interactive CLI and its
authentication and approval controls. They do not start inference themselves.

Claude uses its supported MCP channel interface. Codex uses a private app-server
for the same visible TUI, and queues messages to that server's exact thread.
For a new plain Codex launch, the supervisor creates and names an empty thread,
then opens that exact thread in the visible TUI. This starts no model turn.
A private TUI transport stops the link before a conversation change reaches
Codex. The terminal still works, but its link needs a new terminal after `/new`,
resume, fork, or another thread becomes visible to the transport. Explicit
resume/fork launch forms cannot yet establish a safe live link. Sessions started
without the bridge need a new prepared terminal launch. Provider
consent and unsupported versions remain visible, not silently bypassed.

A private, same-user launcher socket carries bounded messages. A random token
binds each terminal lifetime; a separate client identity binds each MCP process.
The app checks current Canvas membership and live edges on every send. There is
no terminal-output scraping, synthetic typing, hidden replacement conversation,
permission relay, or inference credential storage. An agent sends a message by
calling a tool; ordinary output is never automatically forwarded.

Each terminal inbox holds at most 16 messages of at most 16 KiB. The app allows
at most 20 sends per minute. Pause or removal prevents future sends and drops
undelivered Claude messages for that edge. A message already accepted by a
provider cannot be recalled. Queued delivery is not a model acknowledgement.

Saved links restore paused. Runtime tokens, message bodies, thread identities,
server endpoints, and enabled state are not part of Canvas persistence. Existing
Ensemble runs keep their independent run and worktree controls.

## Consequences

Provider launch adapters are version-dependent and need direct verification.
Claude custom channels currently require its visible development-channel consent.
Codex needs a private server because MCP config overrides do not use its shared
daemon. These servers are tied to the terminal process, with bounded shutdown.
See `docs/references/canvas-live-sessions.md` for verified interfaces and limits.

## Link resilience and off-screen edits (2026-10-22)

By the user's explicit direction, links must keep working while the Ensemble is
not on screen and while the screensaver runs. This amendment changes three
parts of the decision above.

**Suspension scope.** Suspension applies to one route, not for ever to the
terminal capability. The Codex supervisor sends a `release` operation after its
visible TUI exits, which clears the route and the suspension. A `bind` from a
new supervisor endpoint replaces a route that is dead, stale, released, or
suspended; it is still refused while a live agent holds the route. A normal
Ctrl-D exit therefore no longer needs a new terminal: the user runs `codex`
again. The MCP bridge also stays alive through a lost launcher link and
reconnects with bounded backoff instead of exiting.

**Off-screen mutation.** Mutating tools need an Ensemble that is open in the
workspace, not an Ensemble that is on screen. Notes, nodes, edges, diagrams,
frames, and export apply while the tab is not selected. (Superseded on
2026-11-12, see the last amendment below: tools that start a terminal no
longer need the Ensemble shown.) Off-screen edits in Allow mode apply
without the user watching; they stay undoable and recorded.

**Power.** While a terminal holds a live, non-suspended agent route, the app
holds a `ProcessInfo` activity with
`.userInitiatedAllowingIdleSystemSleep`. It stops App Nap, sudden termination,
and automatic termination. It never prevents idle system sleep or display
sleep, so the user's power settings still decide when the Mac sleeps.

See [`../references/ensemble-bridge-resilience.md`](../references/ensemble-bridge-resilience.md).

## Named peers (2026-10-18)

The user requested names and `@mentions` for multiple terminal sessions. Card
names define readable aliases in the bridge tools; exact card UUIDs remain the
routing identity. Alias lookup is restricted to current authorized peers and
rejects ambiguity. Native CLI input and file mention controls remain owned by
the CLI. No terminal text is intercepted to implement routing.

## Rafu voice typing (2026-11-07)

Rafu voice acts for the user, so it may type into any terminal card on the
board after the user's consent: a Confirm card in Ask mode, or Allow. MCP
agents keep the rule that they type only into terminals they created or over
a live message link. See [ADR 0035](0035-voice-through-gpt-live.md).

## Amendment (2026-11-07): Rafu answers its own development-channel dialog

The user asked for an automation that selects "yes" when Claude Code shows
"Loading development channels" in an Ensemble terminal in Allow mode. Rafu
starts Claude with `--dangerously-load-development-channels=server:rafu`, so the
dialog appears on every start. This amendment allows one keypress for that one
dialog. The decision above still holds: no terminal text is intercepted to
implement routing, and the amendment does not change tool permissions.

Rules:

- Gates: Rafu's own launcher started this Claude with the Rafu channel flag
  (a `launch` bridge request over the terminal's private token, never an
  inference from output); the Ensemble's Agent control is Allow; and Settings ▸
  Ensemble ▸ "Confirm Rafu's development-channel prompt automatically" is on
  (default on).
- Watch: at most 60 s after the launch (30 s until the 2026-11-09 amendment
  below), at most four samples a second of the visible rows only. No timer runs
  after the window. One attempt per launch.
- Match: the exact dialog for the single channel `server:rafu` with option 1
  selected. Any other channel, extra entry, selected option, or dialog gives no
  match. Folder trust, MCP consent, and tool permission prompts are never
  answered.
- Action: exactly one Return through the existing terminal input path, then a
  visible board notice. If the dialog stays 2 s, Rafu stops and tells the user
  to answer it.
- Terminal content is read for this match only. It is never logged, stored, or
  sent anywhere.
- Token holders: an agent in the terminal can read the private token, so
  (1) a `launch` request is refused while a Claude client is bound and fresh on
  that terminal (the `register` freshness rule, 15 s), and (2) the matcher needs
  the "Enter to confirm" row to be the last non-empty row of the sample. An
  agent therefore cannot open or replace a watch for its own Claude, and dialog
  text it prints above a tool-permission prompt does not match.
- If the folder-trust dialog comes first and the user takes more than 60 s, the
  window ends and the channel dialog is not answered.

Amendment, 2026-11-09: the watch window is 60 s, not 30 s. In a live test the
dialog went unanswered in Allow mode with no notice; a slow Claude start or a
folder-trust dialog first can use most of 30 s. The watch now logs, with states
only, whether it started and why it ended (`docs/references/canvas-live-sessions.md`,
"Diagnostics"). All other rules stand.

## Cross-reference (2026-11-10): `agent_configure`

The MCP server `instructions` string gained one sentence about `agent_configure`. It adds no bridge operation. The
tool is `sensitive` (like `terminal_send`), keeps the creator rule, and always asks for a resume; see the ADR 0035
amendment "`agent_configure`" and
[`../references/agent-cli-commands.md`](../references/agent-cli-commands.md).

## Cross-reference (2026-11-08): view tools

The MCP server `instructions` string gained one sentence about `view_render` and
`view_update`. It adds no new bridge capability and no new permission rule; both
tools follow the same Off / Ask / Allow rules as the other edit tools. See
[ADR 0036](0036-generated-views-on-the-ensemble-board.md).

The bridge gains one operation, `launch`, sent by the `claude` wrapper before it
replaces itself with Claude. Existing operations and their shapes are unchanged.
See [`../references/canvas-live-sessions.md`](../references/canvas-live-sessions.md).

## Amendment (2026-11-12): agent starts without a visible card, and messages to a starting peer

By the user's direction ("until the user starts the terminal it doesn't start
that has to be updated"; "the edges go failed"). This amendment changes two
parts of the "Link resilience and off-screen edits" section above.

**Start without a card view.** The clause "Tools that start a process ... still
need the Ensemble shown, because a terminal card starts its process only
through its view" is superseded. A permitted start (Allow, or Ask after the
user approved) starts the node's shell whether or not the Ensemble is on screen.
When no card can host the terminal (the board is behind another tab, or the
window is hidden) Rafu starts the same Terminal Group pane itself and creates
its terminal view without placing it in a window, so the shell runs. A card that
is shown later reuses that view. The invariant stays: a process starts only in a
terminal node that exists on the board, visible there, and recorded in the
Agents panel; the node need not be on screen. No lease is taken and the user's
view and focus do not move. ADR 0025's presentation lease is unchanged: it
governs which surface shows the view, not whether the process runs.

**Held messages.** A message sent over a Live link to a peer that is still
starting is held, per target terminal, at most 8 messages for 2 minutes, and is
delivered in order when the peer's client registers (or, for Codex, when its
thread and route are known). It no longer turns the link Failed. A Codex
`queue` refusal within 45 seconds of the client connecting is retried every 3
seconds. Failed now means a real failure: a message the peer never took in 2
minutes, a refusal after the start-up window, a full inbox, or the send limit.
A quit agent, a suspended route and a plain shell are not "starting": their
senders still get an error. Held messages are never saved or logged and a
paused or removed link drops them.

The agent guidance (MCP instructions, `rafu-ensemble` skill) tells agents to
start a peer, wait until `list_connections` shows it connected, and then send
the next message. The start prompt is a launch argument typed with the launch
line, so it is already ordered before any channel message.
