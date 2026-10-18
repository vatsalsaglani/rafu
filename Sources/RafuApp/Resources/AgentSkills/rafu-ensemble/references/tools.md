# Rafu Ensemble tools

All tools come from the `rafu` MCP server. Arguments are JSON objects;
unknown keys are rejected. IDs are the UUIDs that `ensemble_describe`
returns. Results are JSON with snake_case keys.

Risk column: **read** never asks; **edit** asks in Ask mode (the user may
choose "Always for This Ensemble"); **sensitive** asks every time in Ask mode.
Off blocks edit and sensitive tools.

| Tool | Risk | Arguments |
|---|---|---|
| `list_connections` | read | — |
| `send_message` | Live link | `destination` (@mention or node ID), `text` (≤ 16 KiB) |
| `receive_messages` | read | — |
| `ensemble_describe` | read | — |
| `note_read` | read | `node_id`, `offset`?, `length`? (≤ 4000 scalars) |
| `note_write` | edit | `node_id`, `text` (≤ 16 KiB), `mode` (append, prepend, replace, insert_after_heading), `heading`? |
| `note_create` | edit | `title`, `markdown`?, `near`?, `x`?, `y`? |
| `node_create` | edit | `kind` (note, terminal, file, image, web, app, mermaid, shape, text, service_icon, frame) and per kind: `text`, `path`, `url`, `bundle_id`/`app_name`, `shape`, `pack_id`+`icon_id`+`label`, `member_ids`; `title`?, `width`?, `height`?, `near`?, `x`?, `y`? |
| `node_update` | edit | `node_id`, `title`?, `x`?, `y`?, `width`? (96–2000), `height`? (64–2000) |
| `node_remove` | sensitive | `node_id` (not your own node) |
| `terminal_create` | edit; sensitive with `agent` or `command` | `title`?, `cwd`? (workspace-relative folder), `agent`?, `command`? (argument array, ≤ 32 items), `prompt`? (claude or codex), `near`?, `x`?, `y`? |
| `terminal_start` | sensitive | `node_id` |
| `terminal_send` | Live link, else sensitive | `node_id`, and `text` (≤ 4 KiB) or `command` (argument array) |
| `edge_create` | edit | `from`, `to`, `kind` (relationship, message), `label`? |
| `edge_remove` | sensitive | `edge_id` |
| `link_set_state` | edit | `edge_id`, `state` (live, paused) |
| `app_open` | sensitive | `bundle_id` or `app_name`, `near`?, `x`?, `y`? |
| `app_inspect` | read | `node_id` |
| `mermaid_set` | edit | `node_id`, `source` (≤ 16 KiB) |
| `icon_search` | read | `query`, `limit`? (1–50) |
| `frame_create` | edit | `title`, `member_ids` (≤ 100) |
| `diagram_build` | edit | `spec` {`nodes` (≤ 40), `edges` (≤ 80), `frame`?, `direction`?}, `near`?, `x`?, `y`? |
| `export` | sensitive | `format` (png, pdf, gif), `target`? (board, selection, frame), `frame_id`?, `scale`? (png 0.5–4), `seconds`? (gif 1–10), `fps`? (gif 1–30) |
| `action_status` | read | `request_id` |

## Limits

- A note holds at most 64 KiB of UTF-8 text. A board holds at most 100 nodes
  and 200 links.
- Titles and labels: at most 120 characters, one line.
- About 30 changes per minute per agent session; at most 4 questions can wait
  for the user on one Ensemble.
- A question that the user does not answer within 12 seconds returns
  `pending_approval`. It stays open in the Agents panel for 10 minutes.
- Agents change the Ensemble only while it is open in a Rafu window.

## Placement

Without `x`/`y`, a new node appears to the right of `near` (or of your own
node) and steps down past other nodes. With `x`/`y`, that point is the new
node's centre. `node_update` takes the top-left corner.

A frame fits its members by itself. `node_update` on a frame moves the frame
and its members; its `width` and `height` are ignored.
