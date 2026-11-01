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
| `terminal_create` | edit; sensitive with `agent` or `command` | `title`?, `cwd`? (workspace-relative folder), `agent`?, `command`? (argument array, ≤ 32 items, ≤ 1,024 bytes each), `prompt`? (claude or codex, ≤ 1,024 bytes), `link`? (true adds a message link, returns `edge_id` and `mention`), `near`?, `x`?, `y`? |
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

- **Typed lines.** Rafu types a launch line, a `command` or `text` into a
  terminal as one line. `command`: at most 32 items, 1,024 bytes per item,
  4,096 bytes for the whole quoted line (quoting can grow it), no control
  characters, never a shell string. `prompt` becomes one item of the launch
  line, so it holds at most 1,024 bytes and its newlines become spaces.
  `terminal_send` `text` holds at most 4,096 bytes. A refused call names the
  limit and the item and leaves no node behind.
- **Long briefs go in a file or a note.** Write the brief, then send a
  one-line prompt or message that names the path or note title and what to do
  with it. `send_message` and note-node `text` hold 16 KiB, `note_write` 16 KiB
  per call, a note 64 KiB.
- **Mermaid.** A diagram renders up to 8000 x 8000 pt (scaled down to a 4 M
  pixel raster); a larger one shows its raw source. `mermaid_set` source holds
  16 KiB. Split big diagrams.
- A note holds at most 64 KiB of UTF-8 text. A board holds at most 100 nodes
  and 200 links.
- Titles and labels: at most 120 characters, one line.
- About 30 changes per minute per agent session; at most 4 questions can wait
  for the user on one Ensemble.
- A question that the user does not answer within 12 seconds returns
  `pending_approval`. It stays open in the Agents panel for 10 minutes.
- Agents change the Ensemble only while it is open in a Rafu window.

## Terminal results

`terminal_create`, `terminal_start` and `terminal_send` return `state`:

- `running`: the node's shell is up. For `terminal_create` and
  `terminal_send` Rafu is typing the line (it waits for the shell to be
  ready, up to about 10 seconds, after the reply). Check `ensemble_describe`
  before you report that an agent runs.
- `stopped`: the shell did not start in 2.5 seconds. The line is **queued,
  not typed**; Rafu keeps up to 8 lines per node for 15 minutes and types
  them when the shell starts, by `terminal_start` or by the user. The
  message gives the reason (four terminals already hold a live view, the
  live-session limit, or a refused start) and the next call.

Starting a terminal moves the user's view to the node (it pans, or zooms in
when the board is zoomed out), because a shell starts only in a node that is
on screen. Results never repeat the typed line.

`send_message` returns `delivered: true` when Rafu queued the message. It does
not mean the peer read it.

## Placement

Without `x`/`y`, a new node appears to the right of `near` (or of your own
node) and steps down past other nodes. With `x`/`y`, that point is the new
node's centre. `node_update` takes the top-left corner.

A frame fits its members by itself. `node_update` on a frame moves the frame
and its members; its `width` and `height` are ignored.
