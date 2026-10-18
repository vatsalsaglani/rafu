# ADR 0026: Live session links on Canvas

- Status: Accepted through the user's explicit direction, 2026-10-18.
- Supersedes ADR 0025's restriction that all relationships are visual only.

## Decision

Any two Canvas nodes can have a relationship. A new link between terminal nodes
permits messages in both directions between their live Claude Code or Codex
sessions. Other node types remain labeled relationships; a file, app, or shell
is not an agent message endpoint. No file text or app capture is sent by a link.

There is no separate Agent card, task form, role selection, or Start Run action.
The user starts a normal Canvas terminal and types `claude` or `codex`. Private
shell startup files add wrappers for these commands without changing the user's
shell configuration. The wrappers preserve the visible interactive CLI and its
authentication and approval controls. They do not start inference themselves.

Claude uses its supported MCP channel interface. Codex uses a private app-server
for the same visible TUI, and queues messages to that server's exact thread.
For a new plain Codex launch, the supervisor creates and names an empty thread,
then opens that exact thread in the visible TUI. This starts no model turn.
A private TUI transport stops the link before a conversation change reaches
Codex. The terminal still works, but its link needs a new terminal after `/new`,
resume, fork, or another thread becomes visible to the transport. Explicit
resume/fork launch forms cannot yet establish a safe live link. Sessions started
without the bridge need a new prepared terminal launch. Provider
consent and unsupported versions remain visible, not silently bypassed.

A private, same-user launcher socket carries bounded messages. A random token
binds each terminal lifetime; a separate client identity binds each MCP process.
The app checks current Canvas membership and live edges on every send. There is
no terminal-output scraping, synthetic typing, hidden replacement conversation,
permission relay, or inference credential storage. An agent sends a message by
calling a tool; ordinary output is never automatically forwarded.

Each terminal inbox holds at most 16 messages of at most 16 KiB. The app allows
at most 20 sends per minute. Pause or removal prevents future sends and drops
undelivered Claude messages for that edge. A message already accepted by a
provider cannot be recalled. Queued delivery is not a model acknowledgement.

Saved links restore paused. Runtime tokens, message bodies, thread identities,
server endpoints, and enabled state are not part of Canvas persistence. Existing
Ensemble runs keep their independent run and worktree controls.

## Consequences

Provider launch adapters are version-dependent and need direct verification.
Claude custom channels currently require its visible development-channel consent.
Codex needs a private server because MCP config overrides do not use its shared
daemon. These servers are tied to the terminal process, with bounded shutdown.
See `docs/references/canvas-live-sessions.md` for verified interfaces and limits.

## Named peers (2026-10-18)

The user requested names and `@mentions` for multiple terminal sessions. Card
names define readable aliases in the bridge tools; exact card UUIDs remain the
routing identity. Alias lookup is restricted to current authorized peers and
rejects ambiguity. Native CLI input and file mention controls remain owned by
the CLI. No terminal text is intercepted to implement routing.
