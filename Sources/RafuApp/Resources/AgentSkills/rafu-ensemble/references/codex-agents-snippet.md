# AGENTS.md snippet for Codex

Codex reads skills from `~/.codex/skills/<name>/SKILL.md`, which "Install for
Codex" in Rafu Settings writes. If you prefer project instructions instead,
copy this block into the repository's `AGENTS.md`:

```markdown
## Rafu Ensemble

When the `rafu` MCP tools are available you run in a terminal node on a Rafu
Ensemble. Call `ensemble_describe` first. Respect its `agent_control` value:
`off` means read only; `ask` means the user approves each change in Rafu (a
`pending_approval` result has a `request_id` for `action_status`); `allow`
means changes run at once. To delegate: `terminal_create` with `agent`,
`prompt` and `link: true` (or `edge_create` kind `message`, then
`link_set_state` live), then `send_message`. Link every claude or codex peer
you start, even one meant for the user; pause the link for quiet, do not skip
it. After `terminal_create` or `terminal_start` read the result `state`, then
`ensemble_describe` and `list_connections`, before you tell the user an agent
runs; `stopped` means the line is queued, not typed. Put a long prompt,
message or brief in a file or a Rafu note and send a one-line prompt or
message that names it (limits: prompt 1,024 bytes, `terminal_send` text 4,096
bytes, `send_message` 16 KiB). If `terminal_send` says no agent is connected
but one runs in that node, link it and set the link live. Keep a Mermaid
diagram under 8000 x 8000 pt; split bigger ones. Use notes (`note_create`, `note_write`) as shared memory,
`diagram_build`/`mermaid_set` for diagrams, and `export` for PNG/PDF/GIF files. Commands are argument arrays,
never shell strings. Never retry an action the user denied.
```
