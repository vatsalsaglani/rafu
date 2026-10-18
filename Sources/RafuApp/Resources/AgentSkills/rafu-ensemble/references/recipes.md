# Ensemble recipes

## Lead and reviewer

1. `ensemble_describe` → note your `caller_node_id`.
2. `note_create {"title": "Plan", "markdown": "# Plan\n## Tasks\n## Findings\n"}`.
3. `terminal_create {"agent": "codex", "title": "Codex — Review", "prompt": "Read the note titled Plan on the Rafu Ensemble and review the change described there. Write findings under Findings."}`.
4. `edge_create {"from": "<you>", "to": "<codex node>", "kind": "message", "label": "review"}`.
5. `link_set_state {"edge_id": "<edge>", "state": "live"}`.
6. Work. Append progress with
   `note_write {"node_id": "<plan>", "mode": "insert_after_heading", "heading": "Tasks", "text": "- [x] parser"}`.
7. When ready: `send_message {"destination": "<codex node>", "text": "Ready for review. See Plan."}`.
8. Read the reply (channel event or `receive_messages`) and `note_read` the
   Findings section.

## Fan out tests

1. `terminal_create {"title": "Unit tests", "command": ["swift", "test", "--filter", "ParserTests"], "cwd": "."}`.
2. `terminal_create {"title": "Lint", "command": ["./script/format.sh", "--lint"]}`.
3. Check progress with `ensemble_describe` (terminal `state`), and ask the
   user to look at the terminal nodes for output. Rafu does not return
   terminal output to agents.

## Draw the plan

`node_create {"kind": "mermaid", "title": "Plan", "text": "flowchart TD\n  A[Parse] --> B[Check]\n  B --> C[Emit]"}`.
Update it with `mermaid_set` as the plan changes.

## Architecture diagram and GIF

1. `icon_search {"query": "load balancer"}`, `icon_search {"query": "database"}`.
2. `diagram_build` with nodes, edges with labels, and `"frame": "Production"`.
3. `export {"format": "gif", "target": "frame", "frame_id": "<frame node id>", "seconds": 4}`.
4. Tell the user the returned `path`.

## Verify an app

1. Build and run the app in a terminal node (`terminal_create` with
   `command`).
2. `app_open {"app_name": "<App Name>"}`.
3. `app_inspect {"node_id": "<app node>"}` and compare the window's controls
   and values with what you expect.
