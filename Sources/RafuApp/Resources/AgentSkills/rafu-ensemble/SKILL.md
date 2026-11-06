---
name: rafu-ensemble
description: Work inside a Rafu Ensemble (a visual board of terminals, notes and diagrams). Use when the rafu MCP tools are available (ensemble_describe, note_write, terminal_create, edge_create, send_message, diagram_build) to inspect the board, start a peer agent such as Codex or Claude Code, link it with a message edge, delegate a task, read replies, keep shared notes, draw diagrams, and export them.
---

# Working in a Rafu Ensemble

You run in a terminal node on a Rafu Ensemble. Rafu exposes the board to you
through the `rafu` MCP server. Every change you make is visible on the board,
logged under "Agents" in the Ensemble bar, and undoable by the user.

## Rules

1. Call `ensemble_describe` first. It returns every node and edge, your own
   node ID (`caller_node_id`) and the **Agent control** setting.
2. Agent control is the user's choice for this Ensemble:
   - `off`: read only. Tell the user; do not retry changes.
   - `ask`: Rafu asks the user before each change. Removing nodes or links,
     starting processes, typing into terminals and exporting
     ask every time.
   - `allow`: changes run at once.
3. A result with `"status": "pending_approval"` has a `request_id`. Do other
   work, then call `action_status` with that ID. Do not repeat the call.
4. If the user denies an action, do not try it again in another way.
5. Paths are workspace-relative. Commands are argument arrays, never shell
   strings: `["swift", "test"]`, not `"swift test && rm x"`.
6. Keep notes short and structured. A note holds at most 64 KiB.
7. **Long text goes in a file or a note.** A prompt, message or brief longer
   than a few lines does not go in the call. Write it to a file (or a Rafu
   note), then send a one-line prompt or message that names the path or note
   title and says what to do with it. This holds for every agent (Claude,
   Codex, others) and for `terminal_create` `prompt`, `terminal_send` and
   `send_message`. The peer can re-read the file after it compacts, and the
   user can see and edit it. Real limits:

   | Where | Limit |
   |---|---|
   | `terminal_create` `prompt` | 1,024 bytes (it becomes one argument of the launch line); newlines turn into spaces |
   | `command` array | 32 items, 1,024 bytes each, 4,096 bytes for the typed line, no control characters |
   | `terminal_send` `text` | 4,096 bytes, typed as one line |
   | `send_message` and note-node `text` | 16 KiB |
   | `note_write` / a whole note | 16 KiB per call / 64 KiB per note |
   | `mermaid_set` source | 16 KiB; the diagram must also render under 8000 x 8000 pt |

   A refused call says which limit it hit and leaves no node behind.

## Inspect

- `ensemble_describe` — nodes (id, kind, title, rect, state, agent) and edges
  (id, from, to, kind, label, state).
- `note_read` — a note's Markdown. Page long notes with `offset`/`length`.
- `list_connections` — peers linked to you, with `@mentions` and link state.

## Delegate to a peer agent

1. Write the brief to a file or a note when it is longer than a few lines
   (rule 7). Then create the peer **and link it in one call**:
   `terminal_create {"agent": "codex", "title": "Codex — Tests", "prompt": "Read the note titled Tests and do what it says", "link": true, "near": "<your node id>"}`
   (`agent` can be `claude`, `codex`, `opencode`, `gemini`, `cursor`, `kimi`,
   `cline`; only `claude` and `codex` take `prompt` and join message links.)
   Starting the terminal **moves the user's view to the new node**, because a
   terminal starts only in a node that is on screen. The result says so.
2. Read the result `state` (same words as `ensemble_describe`):
   - `running`: the shell is up and Rafu is typing the launch line. This does
     not yet mean the agent runs.
   - `stopped`: the node exists but its shell did not start. The line is
     **queued, not typed**; the message says why (for example four terminals
     already hold a live view) and what to call next. Call `terminal_start`
     once that is fixed: Rafu then types the queued line.
3. Verify before you tell the user an agent runs: call `ensemble_describe`
   (the node `state` is `running` and `agent` is set) and `list_connections`
   (the peer is listed). Codex connects after its first Rafu tool call, so a
   Codex peer may show up a little later.
4. **Link peers by default**, also a peer meant for the user to talk to. A
   link costs nothing: pause it (`link_set_state` `paused`) when you want
   quiet; do not skip it. Without `link`, do it by hand:
   `edge_create {"from": "<your node id>", "to": "<new node id>", "kind": "message"}`
   (starts Paused), then `link_set_state {"edge_id": "<edge id>", "state": "live"}`.
   The link shows Live once both terminals run an agent that has connected.
   If `link` was asked and the link could not be made, the result says so and
   keeps the node: use `edge_create` and `link_set_state` yourself.
5. Send work: `send_message {"destination": "<node id or @mention>", "text": "..."}`
   (the new peer's `mention` is in the `terminal_create` result). The result
   has `delivered: true` when Rafu queued it; the peer may not have read it
   yet. A paused link or a peer that is not connected is an error that says so.
6. Read replies: Claude Code receives channel messages automatically; also
   call `receive_messages`.

`terminal_send` uses a Live message link when one exists. Without one, Rafu
types only into terminals **you** created: `text` when an agent is connected in
that node, or a `command` argument array into a shell. Its result has `state`
too: `stopped` means the line is queued, not typed.

**Recovery.** If `terminal_send` says the node has no connected agent for text
but you know an agent runs there (you typed `claude` into a shell node), create
a message link to it (`edge_create` kind `message`), set it live, and use
`send_message`. Do not conclude that you cannot talk to it.

## Shared memory with notes

- `note_create {"title": "Plan", "markdown": "# Plan\n- [ ] step"}`
- `note_write {"node_id": "...", "mode": "append", "text": "- [x] done"}`
- Modes: `append`, `prepend`, `replace`, `insert_after_heading` (with
  `heading`, the heading text without `#`).
- Agree with peers on one note per topic: "Plan", "Decisions", "Findings".

## Diagrams

- Mermaid: `node_create {"kind": "mermaid", "title": "Plan", "text": "flowchart LR\n  A[Design] --> B[Build] --> C[Test]"}`,
  then `mermaid_set {"node_id": "...", "source": "..."}` to change it.
  Rafu draws a diagram up to **8000 x 8000 pt** (larger ones are scaled down
  to fit memory, so a big diagram is small on the board); past 8000 pt it
  shows the raw source instead. Keep a diagram under that: split a large
  schema into several diagrams (one per area) and group them in a frame.
- Architecture diagrams with icons:
  1. `icon_search {"query": "queue"}` returns `pack_id`, `icon_id`, `label`.
     The Common pack is always there; AWS, Azure and Google Cloud packs exist
     only if the user imported them.
  2. `diagram_build` with a spec builds and lays out the whole diagram in
     one undoable step:

     ```json
     {"spec": {
       "nodes": [
         {"id": "web", "label": "Web app", "pack_id": "common", "icon_id": "browser"},
         {"id": "api", "label": "API", "pack_id": "common", "icon_id": "api"},
         {"id": "db", "label": "Orders DB", "pack_id": "common", "icon_id": "database"},
         {"id": "why", "kind": "note", "label": "Writes go through the API"}
       ],
       "edges": [
         {"from": "web", "to": "api", "label": "HTTPS"},
         {"from": "api", "to": "db"}
       ],
       "frame": "Checkout",
       "direction": "right"}}
     ```

     The result maps each local `id` to the created node ID
     (`created_nodes`). The longest chain of edges goes on one line and
     branches go beside it. Gaps grow with the edge labels, so keep labels
     short (a few words); a label that does not fit between two nodes is
     shortened with "…" on the board.
- Single nodes: `node_create` kinds `service_icon` (`pack_id`, `icon_id`,
  `label`), `shape` (`shape`: rectangle, ellipse, diamond), `text`, `note`.
- Frames group nodes: `frame_create {"title": "Backend", "member_ids": [...]}`.
  A frame always fits its members: it grows, shrinks and moves with them.
  Moving a frame moves its members. Do not set a frame's `width` or
  `height`; Rafu ignores them. To change a frame, move its members.
- Links between diagram nodes: `edge_create` with `kind` `relationship` and a
  `label`.
- Export: `export {"format": "png", "scale": 2}`, `{"format": "pdf"}`, or
  `{"format": "gif", "seconds": 3, "fps": 12}` for an animated flow where dots
  move along the links. `target` is `board` (default), `selection`, or
  `frame` with `frame_id`. Files go to the workspace `exports/` folder; the
  result has the workspace-relative `path`.

## Other tools

- `node_create` kinds `file`/`image` (`path`), `web` (`url` on localhost).
- `node_update` renames, moves (`x`, `y` top-left) or resizes a node.
- `node_remove`, `edge_remove` — always confirmed by the user in Ask mode.
- `terminal_start` starts a stopped terminal node and moves the user's view
  to it. Read the result `state`; lines queued for the node are typed when
  its shell is up.

See `references/tools.md` for every tool and its limits, and
`references/recipes.md` for longer workflows.
