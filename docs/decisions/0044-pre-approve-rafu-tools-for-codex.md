# ADR 0044: Pre-approve Rafu's own tool server for the agents in Ensemble terminals

- **Status:** Accepted (2026-11-21) on the user's direction. The effect of the Codex setting `approve` is verified
  only in part (see "Evidence" and "Hand checks"). GUI checks pending.
- **Date:** 2026-11-21
- **Amended 2026-11-21:** the decision now covers Claude Code as well as Codex (see "Amendment: Claude Code"). The
  file name keeps "for-codex" so existing links stay valid.
- **Amended 2026-11-21 (2):** decision 5 is reversed for tool approvals (the Codex proxy follows the MCP elicitation
  method; see decision 5). Decisions 1 to 4 stay.
- **Related:** [`codex-app-server-approvals.md`](../references/codex-app-server-approvals.md),
  [`canvas-live-sessions.md`](../references/canvas-live-sessions.md),
  the decision about answering agent requests from the Up next row
  ([`0042-answer-agent-requests-from-up-next.md`](0042-answer-agent-requests-from-up-next.md)),
  the decision about full access agents in Ensemble terminals
  ([`0041-full-access-agents-in-ensemble-terminals.md`](0041-full-access-agents-in-ensemble-terminals.md)),
  the Ensemble phase ([`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)).

## Context

A Codex agent in an Ensemble terminal calls Rafu's tools (`ensemble_describe`, `list_connections`, `send_message`,
`terminal_create` and the others). Codex asked a second question before each new tool: "Allow the rafu MCP server
to run tool "ensemble_describe"?" The user had to answer it in the terminal, once for every tool name.

The second question has no value. Every Rafu tool call already passes the Ensemble Agent control setting (Off,
Ask or Allow). In Ask, a tool that changes the Ensemble raises a Rafu approval that the user answers in Rafu. In
Off, every call is refused. The check runs again when the call executes (`CanvasAgentActions`). So the Codex
question only repeats a decision that Rafu makes itself.

The question is a Codex MCP elicitation (`mcpServer/elicitation/request`). It is not one of the four request kinds
that the Codex proxy follows (command, file change, permissions, question), so it never appeared in the Up next row.
It showed in the terminal only, as "Needs you · Answer in the terminal". (Later the same day the proxy began to
follow this method for other servers' tool approvals; see decision 5.)

## Decision

1. **Rafu's own server is pre-approved for Codex.** The launcher adds one setting to the private app server of
   each Ensemble Codex terminal: `-c mcp_servers.rafu.default_tools_approval_mode="approve"`. It sits with the other
   `mcp_servers.rafu.*` settings that the launcher already injects.
2. **Scope is exactly one server in one terminal.** The setting names the `rafu` server only. It reaches only the
   app server that this terminal's launcher starts (a private socket). Rafu never writes `~/.codex/config.toml`.
   Other MCP servers keep their own approval behaviour. Codex outside an Ensemble terminal is unchanged.
3. **Ensemble Agent control stays the only gate.** Off, Ask and Allow decide every Rafu tool call, as before.
   Nothing in this decision lowers a Rafu check.
4. **Tool hints.** The Rafu tool list marks the tools that only read (`ensemble_describe`, `note_read`,
   `action_status`, `icon_search`, `list_connections`) with the MCP annotation `readOnlyHint: true`. A tool that
   changes anything is never marked. The hint is a fallback for the Codex mode `writes`, if `approve` proves
   not to be enough. It does not replace decision 1.
5. ~~**No Up next support for other servers' approvals.** The user decided not to build it. A Codex approval for an
   MCP server that is not Rafu keeps showing in the terminal only. The Codex proxy does not follow the elicitation
   method.~~ **Reversed for tool approvals (2026-11-21), on the user's direction.** A request for another server's
   MCP tool is answerable from the peek, for Claude Code and for Codex. The Codex proxy now follows
   `mcpServer/elicitation/request`; see the amendments "Claude requests for MCP tools answer in the peek" and "Codex
   requests for MCP tools answer in the peek" in
   [`0042-answer-agent-requests-from-up-next.md`](0042-answer-agent-requests-from-up-next.md). Decisions 1 to 4 stay:
   Rafu's own server stays pre-approved, so its tools should raise no question. A generic MCP form or URL
   elicitation still shows in the terminal only.

## Amendment: Claude Code (2026-11-21)

A Claude Code agent in an Ensemble terminal asked "Tool use · rafu — Send Message Tool (MCP) … Do you want to
proceed?" before it called a Rafu tool. This is the same second question, so the same reasoning applies.

1. **Mechanism.** The Claude launcher adds `--allowedTools=mcp__rafu` after `--mcp-config=…` and
   `--dangerously-load-development-channels=server:rafu`. `mcp__rafu` is a server-level permission spec: it covers
   every tool of the `rafu` server. The `=` form is required, because `--allowedTools` is variadic like the other
   two flags, and the spaced form would take the user's prompt as a tool name.
2. **Scope.** One Claude session (the launch arguments), the `rafu` server only. Rafu never writes
   `~/.claude/settings.json`. Other MCP servers and the built-in tools (Bash, Edit, Write) keep their prompts.
   Claude outside an Ensemble terminal is unchanged.
3. **Ensemble Agent control stays the only gate** (Off, Ask, Allow), as for Codex.
4. **Open questions (not solved).** A `--allowedTools` the user types after Rafu's flags may replace or add to
   Rafu's entry; Rafu does not merge them. A user `--permission-mode` interacts with the allow list in ways that
   Claude decides. If a Claude release stops matching the server-level name, the fallbacks are `mcp__rafu__*`, then
   one entry per tool name.
5. **Equivalent for Codex.** Claude's `--allowedTools` plays the role of the Codex setting `default_tools_approval_mode`.

Evidence, Claude Code 2.1.330: `claude --help` lists `--allowedTools, --allowed-tools <tools...>`;
`claude --allowedTools=mcp__rafu mcp list` runs; the binary documents server-level specs of the form
`mcp__server`. Not verified live: that the "Tool use" question no longer shows. It needs the hand check below.

## Alternatives considered

- **Show the elicitation in Up next.** Rejected at first (user decision). Chosen later the same day for other
  servers' tool approvals (decision 5). It needed no new kind and no new sanitizer: the Claude tool call kind and
  the tool-name rule were reused. For Rafu's own server it stays redundant, because the `approve` setting should
  remove the question.
- **Write the setting to `~/.codex/config.toml`.** Rejected. It changes the user's own Codex for every terminal and
  every other tool, and it is a durable edit that the user did not ask for.
- **Mode `writes` with annotations.** Kept as the fallback (decision 4). It trusts the read-only hint of each tool,
  so it is a weaker base than `approve` for a server that Rafu owns.
- **Do nothing.** Rejected: the user decides twice for one action.

## Consequences

- A Codex agent in an Ensemble terminal calls Rafu tools without a second prompt (to be confirmed by hand).
- If Agent control is Ask, a changing tool still raises a Rafu approval. If it is Off, the tool is refused.
- A Codex agent that tries to call a Rafu tool that Agent control refuses gets the Rafu refusal, not a Codex
  question.
- The Codex setting is a string in the launcher. A Codex release that renames or removes the key makes Codex ask
  again (or refuse to start if it rejects unknown keys in `-c`); the launcher test pins the exact pair.

## Evidence

Codex 0.171.0, 2026-11-21:

- `codex -c mcp_servers.zzz.command="/bin/true" -c mcp_servers.zzz.default_tools_approval_mode="bogus" mcp list`
  fails with: unknown variant `bogus`, expected one of `auto`, `prompt`, `writes`, `approve`.
- The same command with `"approve"` loads and lists the server (the value is valid).
- The binary holds the setting `default_tools_approval_mode` in the MCP server configuration (beside
  `enabled_tools`, `disabled_tools` and `tool_timeout_sec`), an enumeration with `auto`, `prompt`, `writes` and
  `approve`, and a per-tool `approval_mode`.
- Not verified: that `approve` stops the "Allow the rafu MCP server to run tool" question. The meaning of
  `approve` as "approve without asking" is inferred from the name. It needs a hand check.

## Revisit trigger

A Codex release that changes the value names or the key, a hand check that shows `approve` still prompts (then try
`writes` with the hints, then the per-tool `approval_mode`). (The earlier trigger "a wish to answer other servers'
approvals from the Up next row" was met on 2026-11-21 and is now built; its hand checks are in the Codex amendment of
the decision about answering agent requests from Up next.)

## Hand checks

Claude: start a Claude agent with `terminal_create` and a link, and make it send a Rafu message. No "Tool use · rafu
… proceed?" question may show. Agent control Ask still asks for a changing tool; Off refuses it.

Codex:

Start a Codex agent with `terminal_create` and a link; ask it to call `ensemble_describe` and `list_connections`
and see that no "Allow the rafu MCP server to run tool" question shows. In Ask, check that a changing tool (for
example `note_create`) still raises a Rafu approval, and in Off that it is refused.
