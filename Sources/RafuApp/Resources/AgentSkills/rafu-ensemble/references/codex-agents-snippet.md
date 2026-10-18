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
means changes run at once. To delegate: `terminal_create` with `agent` and
`prompt`, `edge_create` kind `message`, `link_set_state` live, then
`send_message`. Use notes (`note_create`, `note_write`) as shared memory,
`diagram_build`/`mermaid_set` for diagrams, `export` for PNG/PDF/GIF files,
and `app_open` + `app_inspect` to verify apps. Commands are argument arrays,
never shell strings. Never retry an action the user denied.
```
