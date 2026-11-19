# ADR 0041: Full access agents in Ensemble terminals

- **Status:** Accepted (2026-11-19) on the user's direction ("add a Full access option for Codex agents started in
  Rafu Ensemble terminals"). Revised 2026-11-20 after a security review: the launcher needs a one-time grant from
  the app. GUI checks pending (listed below).
- **Date:** 2026-11-19
- **Number note:** 0041 was free on main when this was written. The decision record about answering agent
  requests from the Up next row may also claim 0041; whichever merges second takes the next free number and fixes
  its links.
- **Related:** [`codex-full-access.md`](../references/codex-full-access.md),
  [`agent-cli-commands.md`](../references/agent-cli-commands.md), the Ensemble Agent control model
  ([`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)).

## Context

To give a Codex peer full access, the user had to open its terminal and run `/approvals`. Typing
`codex --dangerously-bypass-approvals-and-sandbox` into a shell node did not join the board. `agent_configure`
deliberately left out Codex `danger-full-access`. Rafu's Codex start runs the terminal UI as
`codex --remote … resume <thread>`, and Codex 0.170.0 refuses permission flags in that form.

## Decision

1. `terminal_create` takes `access`: `default` or `full`, Codex only (any other agent, or no agent, is refused with
   a reason). `agent_configure` offers Codex mode `full`.
2. Rafu builds the launch line `codex --dangerously-bypass-approvals-and-sandbox …` as an argument vector. Rafu's
   launcher always removes that flag (and its `--yolo` alias) from the terminal UI's arguments.
3. **One-time grant.** When the user approves a full request, the app stores one grant for that terminal node (15
   minutes, in memory). Before it starts the private Codex server, the launcher asks the app for the grant over the
   terminal's private bridge token. With the grant, the switch on and Agent control not Off, the server starts with
   `-c approval_policy="never" -c sandbox_mode="danger-full-access"`, and the grant is used up. Without it, the
   launcher prints one line on stderr (full access needs the Rafu setting and approval) and starts the default
   server. The agent joins the board through the unchanged Codex proxy either way.
4. A Settings switch, Settings > Ensemble > "Allow Full access agents", is Off by default. Off refuses every full
   request with a message that names the switch, and the activity log names the switch. Agent control Off refuses
   as for every change.
5. With the switch On, every full request asks the user, in Ask and also in Allow. No "Always for This Ensemble"
   grant and no voice session grant covers it. The switch is checked again when an approved or queued call runs.
6. Guards on agent input: a `prompt` that starts with `-` is refused; `terminal_send` text and `command` elements
   that contain the bypass flag, `--yolo` or `danger-full-access` (as a substring, also inside `sh -c "…"`) are
   refused. A `command` can run any program, so these refusals are a guard, not a boundary. The boundary is the
   grant in point 3.
7. The terminal node shows a "Full access" badge (shield symbol and words; VoiceOver "Full access, skips approval
   prompts"), and so does its Agents / Up next row, also after the app restarts (from the saved node flag). No start
   and no grant is saved: a reopened node starts a plain shell, and saved layouts stay inert. A change to a node
   with the flag says in the question that the conversation keeps full access.

## Alternatives considered

- **Pass the flag to the terminal UI.** Refused by Codex for `--remote … resume`.
- **`-s danger-full-access -a never` on the terminal UI.** Same refusal: both are permission overrides.
- **Start a new remote session instead of resuming a prepared thread.** Accepts the flag, but loses the thread that
  Rafu binds before the UI starts (the bridge route), so the agent would not join the board.
- **Set permissions in `thread/start` parameters.** Possible, but unverified against 0.170.0; the server
  configuration route was verified end to end.
- **Translate the flag for every caller.** Rejected in review: a prompt, a typed line or a shell command could then
  give full access with no switch and no question.
- **Allow mode skips the question.** Rejected: full access removes every later check, so it always asks, like an
  agent restart.

## Consequences

- A new Codex session started with the bypass flag in a Rafu Ensemble shell gets no full access: the launcher
  removes the flag and says why, unless the user approved a full request for that node.
- **Accepted gap (user decision, 2026-11-20): `codex resume`, `fork`, `exec` and `review` skip the grant.** The
  Rafu launcher does not attach to these subcommands (`CanvasBridgeLaunch.shouldAttach` is false), so it runs the
  real Codex with the arguments unchanged. Any full-access spelling on them works with the switch Off and with no
  badge. Examples: `codex resume --last --yolo`, `codex exec --dangerously-bypass-approvals-and-sandbox "task"`,
  `codex resume --last -s danger-full-access -a never`, `codex resume --last -c sandbox_mode=danger-full-access`.
  This pass-through existed before this decision. The text and command guards catch only literal spellings, so an
  agent can also reach it with shell quoting (for example `--yo""lo`) through an approved `terminal_send` or
  `command`. The switch and the badge therefore cover new sessions that Rafu starts, not every Codex process in an
  Ensemble terminal.
- An `agent_configure` change to mode `full` types `codex resume <id> --dangerously-bypass-approvals-and-sandbox`.
  It gets full access directly through the gap above, and its grant is not used. That grant stays open for up to
  15 minutes, and the next new Codex start with the flag in that node uses it with no new question.
- **Accepted risk:** a Codex conversation that ran with full access keeps it when it resumes, also on a default
  server. An Agent History Resume, a model-only `agent_configure` change, or a restart of that conversation goes on
  with full access and asks nothing new about it (the `agent_configure` question names it). This is Codex's own
  behaviour. Rafu never clears the badge, and a later `read_only` or `workspace_write` change cannot lower it (Codex
  refuses that change in the remote form; a pre-existing limit).
- The badge can stay on a node whose shell the user restarted by hand. It errs toward warning.

## Revisit trigger

A Codex release that accepts permission overrides on `--remote … resume`, a verified per-thread permission API, or
a request for the same option for Claude Code.

## GUI checks pending

Switch off refusal text; Ask question shows the "Full access:" line and no Always button; badge on the card header
and the Up next row, with VoiceOver, also after an app restart; the peer joins the board and runs `swift build` with
no prompt; a hand-typed flag on a new session prints the stderr line and gives no full access; a hand-typed
`codex resume --last --yolo` does get full access (the accepted gap).
