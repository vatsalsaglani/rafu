# Ensemble recipes

## Lead and reviewer

1. `ensemble_describe` → note your `caller_node_id`.
2. `note_create {"title": "Plan", "markdown": "# Plan\n## Tasks\n## Findings\n"}`.
3. `terminal_create {"agent": "codex", "title": "Codex — Review", "prompt": "Read the note titled Plan on the Rafu Ensemble and review the change described there. Write findings under Findings.", "link": true}`.
   The brief lives in the Plan note; the prompt is one short line that names it.
4. Read the result `state`. If it is `stopped`, the line is queued: follow the
   message, then call `terminal_start`. Then check `ensemble_describe` and
   `list_connections` before you tell the user Codex runs. Wait until
   `list_connections` shows the Codex peer `connected` before step 7.
5. `link: true` already added the message link. By hand it is
   `edge_create {"from": "<you>", "to": "<codex node>", "kind": "message", "label": "review"}`
   then `link_set_state {"edge_id": "<edge>", "state": "live"}`.
6. Work. Append progress with
   `note_write {"node_id": "<plan>", "mode": "insert_after_heading", "heading": "Tasks", "text": "- [x] parser"}`.
7. When ready: `send_message {"destination": "<codex node>", "text": "Ready for review. See Plan."}`.
8. Read the reply (it arrives as a channel event for Claude Code or as a new
   turn for Codex) and `note_read` the Findings section.

## Answer a message from a peer

A received message starts with `Ensemble message from @codex-review (peer id
<uuid>).` Reply with `send_message {"destination": "@codex-review", "text":
"Done. See Findings."}`. Use the peer ID when two peers share a name. If a send
returns Held, do not repeat it; `list_connections` shows `pending` and, after
5 minutes, `lastDelivery`. A Codex receiver takes the message when its current
turn ends; if it waits idle at its prompt and does not answer, start it with
`terminal_send`.

## Hand a long brief to a peer

1. Write the brief to a file in the workspace (or `note_create` a note).
2. `terminal_create {"agent": "claude", "title": "Claude — Docs", "prompt": "Read docs/briefs/schema.md and do what it asks", "link": true}`.
   Do not write "wait for the next message" in a prompt: a peer that is told to
   wait may poll in a loop. Give it the task and tell it to reply with
   `send_message` and then stop. A message starts its next turn.
3. Later messages follow the same rule: `send_message {"destination": "@claude-docs", "text": "Brief updated in docs/briefs/schema.md; redo step 2"}`.

## An agent you typed into a shell node

You ran `terminal_send {"command": ["claude"]}` in a shell node, and a later
`terminal_send` with `text` says there is no connected agent. Link it:
`edge_create` kind `message` from your node to that node, `link_set_state`
live, then `send_message`. The link shows Live once the agent connects.

## Fan out tests

1. `terminal_create {"title": "Unit tests", "command": ["swift", "test", "--filter", "ParserTests"], "cwd": "."}`.
2. `terminal_create {"title": "Lint", "command": ["./script/format.sh", "--lint"]}`.
3. Check progress with `ensemble_describe` (terminal `state`), and ask the
   user to look at the terminal nodes for output. Rafu does not return
   terminal output to agents.

## Draw the plan

`node_create {"kind": "mermaid", "title": "Plan", "text": "flowchart TD\n  A[Parse] --> B[Check]\n  B --> C[Emit]"}`.
Update it with `mermaid_set` as the plan changes. A diagram renders up to
8000 x 8000 pt: for a large schema (many tables), make one diagram per area
and put them in a frame instead of one huge diagram.

## Architecture diagram and GIF

1. `icon_search {"query": "load balancer"}`, `icon_search {"query": "database"}`.
2. `diagram_build` with nodes, edges with labels, and `"frame": "Production"`.
3. `export {"format": "gif", "target": "frame", "frame_id": "<frame node id>", "seconds": 4}`.
4. Tell the user the returned `path`.
