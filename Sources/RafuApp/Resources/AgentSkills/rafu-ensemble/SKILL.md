---
name: rafu-ensemble
description: Work inside a Rafu Ensemble (a visual board of terminals, notes, diagrams and apps). Use when the rafu MCP tools are available (ensemble_describe, note_write, terminal_create, edge_create, send_message, diagram_build, app_open) to inspect the board, start a peer agent such as Codex or Claude Code, link it with a message edge, delegate a task, read replies, keep shared notes, draw diagrams, export them, and open and verify apps.
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
     starting processes, typing into terminals, opening apps and exporting
     ask every time.
   - `allow`: changes run at once.
3. A result with `"status": "pending_approval"` has a `request_id`. Do other
   work, then call `action_status` with that ID. Do not repeat the call.
4. If the user denies an action, do not try it again in another way.
5. Paths are workspace-relative. Commands are argument arrays, never shell
   strings: `["swift", "test"]`, not `"swift test && rm x"`.
6. Keep notes short and structured. A note holds at most 64 KiB.

## Inspect

- `ensemble_describe` — nodes (id, kind, title, rect, state, agent) and edges
  (id, from, to, kind, label, state).
- `note_read` — a note's Markdown. Page long notes with `offset`/`length`.
- `list_connections` — peers linked to you, with `@mentions` and link state.

## Delegate to a peer agent

1. Create the peer:
   `terminal_create {"agent": "codex", "title": "Codex — Tests", "prompt": "Run the test suite and report failures", "near": "<your node id>"}`
   (`agent` can be `claude`, `codex`, `opencode`, `gemini`, `cursor`, `kimi`,
   `cline`; only `claude` and `codex` take `prompt` and join message links.)
2. Link it: `edge_create {"from": "<your node id>", "to": "<new node id>", "kind": "message", "label": "tests"}`.
   A new message link starts Paused.
3. Go live: `link_set_state {"edge_id": "<edge id>", "state": "live"}`. The
   link shows Live once both terminals run an agent that has connected
   (Codex connects after its first Rafu tool call).
4. Send work: `send_message {"destination": "<node id or @mention>", "text": "..."}`
   or `terminal_send {"node_id": "...", "text": "..."}`.
5. Read replies: Claude Code receives channel messages automatically; also
   call `receive_messages`.

`terminal_send` uses a Live message link when one exists. Without one, Rafu
types only into terminals **you** created: text into an agent terminal, or a
`command` argument array into a shell terminal.

## Shared memory with notes

- `note_create {"title": "Plan", "markdown": "# Plan\n- [ ] step"}`
- `note_write {"node_id": "...", "mode": "append", "text": "- [x] done"}`
- Modes: `append`, `prepend`, `replace`, `insert_after_heading` (with
  `heading`, the heading text without `#`).
- Agree with peers on one note per topic: "Plan", "Decisions", "Findings".

## Diagrams

- Mermaid: `node_create {"kind": "mermaid", "title": "Plan", "text": "flowchart LR\n  A[Design] --> B[Build] --> C[Test]"}`,
  then `mermaid_set {"node_id": "...", "source": "..."}` to change it.
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
     (`created_nodes`).
- Single nodes: `node_create` kinds `service_icon` (`pack_id`, `icon_id`,
  `label`), `shape` (`shape`: rectangle, ellipse, diamond), `text`, `note`.
- Frames group nodes: `frame_create {"title": "Backend", "member_ids": [...]}`.
  Moving a frame moves its members.
- Links between diagram nodes: `edge_create` with `kind` `relationship` and a
  `label`.
- Export: `export {"format": "png", "scale": 2}`, `{"format": "pdf"}`, or
  `{"format": "gif", "seconds": 3, "fps": 12}` for an animated flow where dots
  move along the links. `target` is `board` (default), `selection`, or
  `frame` with `frame_id`. Files go to the workspace `exports/` folder; the
  result has the workspace-relative `path`.

## Open and verify apps

1. `app_open {"app_name": "Simulator"}` or `{"bundle_id": "com.apple.Safari"}`
   opens the app and shows it in an app node.
2. `app_inspect {"node_id": "..."}` returns the Accessibility summary of the
   docked window (titles, buttons, values). It needs the user's
   Accessibility permission; if it is missing, ask the user to allow Rafu in
   System Settings > Privacy & Security > Accessibility.
3. Use the summary to check your change, then report what you saw.

## Other tools

- `node_create` kinds `file`/`image` (`path`), `web` (`url` on localhost),
  `app` (adds the node without launching).
- `node_update` renames, moves (`x`, `y` top-left) or resizes a node.
- `node_remove`, `edge_remove` — always confirmed by the user in Ask mode.
- `terminal_start` starts a stopped terminal node.

See `references/tools.md` for every tool and its limits, and
`references/recipes.md` for longer workflows.
