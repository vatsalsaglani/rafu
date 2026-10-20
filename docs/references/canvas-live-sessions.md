# Canvas live session boundary

- Applies to: Canvas terminal session links (ADR 0026) and their shell bridge
  strategies (ADR 0028).
- Last checked: 2026-10-19, macOS 27.0.1 (26A434), Apple Swift 6.4
  (swiftlang-6.4.0.34.1), Claude Code 2.1.303, Codex CLI 0.163.0. Source checks are distinct from live model verification.
  The Claude launch argument form was re-verified on 2026-10-21 against Claude
  Code 2.1.304 (see "Claude bridge flags are variadic").

## Rules and verified provider interfaces

Claude accepts an MCP stdio channel with the experimental `claude/channel`
capability and `notifications/claude/channel` notifications. The startup flag
`--dangerously-load-development-channels=server:rafu` requires provider consent.
Rafu passes it, and `--mcp-config=<path>`, in the single-token `=` form only;
see "Claude bridge flags are variadic".
It does not change tool permissions. MCP protocol 2026-07-28 cannot carry these
notifications; the bridge selects 2025-11-25 and legacy negotiation.
A channel notification is not a model acknowledgement.

Sources: https://code.claude.com/docs/en/channels-reference and
https://code.claude.com/docs/en/mcp .

Codex 0.163.0 supplies `_meta.threadId` on MCP tool calls. Shell environment
`CODEX_THREAD_ID` is not an MCP startup identity. A plain launch creates an empty thread with `thread/start`, names it with
`thread/name/set` to make it resumable, and opens that same thread in the visible
TUI. A no-inference probe confirmed that resume fails before the naming step
and succeeds after it. No `turn/start` is used. No thread is guessed from a title,
working directory, history file, or terminal output.

MCP config overrides force the ordinary Codex launch away from its shared daemon.
A private `app-server --listen unix://...` with the visible TUI attached through
`--remote` keeps one real conversation. `queue --remote ... --thread ... --message`
adds to that same thread. The versioned source shows idle wakeup and delivery
after an active turn. An interrupted thread can retain queued input until resumed.

Sources (version rust-v0.163.0):
- https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/core/src/mcp_tool_call.rs
- https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/daemon_startup.rs
- https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/ext/queue/src/service.rs

## Shell and resource ownership

Each prepared terminal owns private startup files. `CanvasShellBridgeStrategy`
in `CanvasTerminalBootstrap.swift` selects the mechanism by shell basename.
`supportsBridge(shellBasename:)` is true when the strategy is not
`environmentOnly`, which means "wrapper-directory PATH order is guaranteed after
the user's startup files". No user rc file is ever edited. See the per-shell
table below and ADR 0028.

The Codex supervisor uses a short private Unix socket directory, isolates the
server process group from terminal Ctrl-C, and terminates the server when the
visible TUI ends. Readiness and shutdown are bounded. Queue processes discard
output and receive arguments directly, with no shell interpolation.

The broker stores only live capability state. Every send checks the terminal
lifetime and current edge. Messages are bounded, not logged, and not saved with
boards. Disconnected nodes cannot receive new messages. Restored edges start Paused
and resume per link (see "Per-link states"). Generic app/file links grant no capture or filesystem capability.

## Per-shell bridge strategies (verified 2026-10-19)

Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1 (26A434). On `main`: format
lint clean, build with 0 new warnings, parallel suite 250 + 2563 tests passed,
`--no-parallel` (CI mode) 250 + 2563 passed, `./script/build_and_run.sh --verify`
launched Rafu Lightning.

| Shell | Mechanism |
|---|---|
| zsh | `ZDOTDIR` forwarding; user startup files run, then the wrapper PATH |
| bash | `--noprofile --rcfile <private rc>`; the private rc runs the login files |
| fish | `-l -i --init-command 'set -gx PATH $RAFU_CANVAS_WRAPPER_DIR $PATH'` |
| sh, dash, ksh, mksh | argv `["-i"]` (no `-l`) plus `ENV=<private>/env.sh` |
| tcsh, csh | argv `["-i"]`; `HOME` points at the private directory |
| nu | login arguments plus `-e '$env.PATH = ($env.PATH \| prepend $env.RAFU_CANVAS_WRAPPER_DIR)'` |
| xonsh | login arguments plus `-i`; `XONSHRC_DIR` gains a private `rc.d` |
| elvish, any other basename | `environmentOnly`: PATH prepended in the spawn environment only |

Every inline command is a static literal that reads environment variables at run
time; the private files hold only static text. Paths reach the shell only through
environment variables. The private directory is 0700 and its files 0600; cleanup
is unchanged. Tests assert that no written file contains the capability token,
the socket path, or base-environment values (fixture marker
`/fixture/$(evil)`).

Details that are not derivable from the code:

- **fish**: `--init-command` runs after `config.fish` and `conf.d`, so it wins
  over `fish_add_path`. Verified by hand with fish 4.0.2
  (`/opt/homebrew/bin/fish`): `PATH[1]` was the wrapper directory with the
  user's tide, fzf, and z plugins loaded and `fish_add_path` present.
- **POSIX shells — the naive form fails.** `ENV=<private>` together with
  `-l -i` does NOT work when the user's `~/.profile` sets `ENV`: the profile
  runs first and overrides `ENV`, so the private file never runs. Proven for
  `/bin/sh`, `/bin/dash`, and `/bin/ksh`. The implementation therefore drops
  `-l`, carries the user's value in `RAFU_CANVAS_USER_HAD_ENV` and
  `RAFU_CANVAS_USER_ENV`, and the private `env.sh` restores it, emulates the
  login sequence (`/etc/profile`, `~/.profile`) when the catalog marks the
  shell login, sources the user's `ENV` file (default `${ENV-}` for sh and
  dash, `${ENV-$HOME/.kshrc}` for ksh, `${ENV-$HOME/.mkshrc}` for mksh, with
  `~/` expansion and an `eval` of the user's own value only when it contains
  `$` or a backtick, matching POSIX `ENV` expansion), and only then prepends
  the wrapper directory.
- **csh family**: `HOME` is the private directory and `RAFU_CANVAS_USER_HOME`
  holds the real one. The private `.tcshrc` restores `HOME`, runs
  `/etc/csh.login` (login variant), `~/.tcshrc` or `~/.cshrc`, `~/.login`
  (login variant), then `setenv PATH "${RAFU_CANVAS_WRAPPER_DIR}:${PATH}"`.
  Only `/etc/csh.cshrc` runs while `HOME` is still private; on macOS it sets
  only the prompt. History loads from the real `HOME`.
- **nu**: `-e` runs after `env.nu`, `config.nu`, `login.nu`, and autoload, then
  the REPL. Source: nushell.sh/book/configuration.html "Launch Stages", fetched
  2026-10-19 (the book cites 0.116.0). Not verified by execution; nu is not
  installed.
- **xonsh**: `XONSHRC_DIR` becomes the user's value, or the default
  `/etc/xonsh/rc.d:<XDG_CONFIG_HOME or ~/.config>/xonsh/rc.d`, plus
  `<private>/xonshrc.d`, which holds `zzzz-rafu-canvas.xsh` with
  `$PATH.insert(0, $RAFU_CANVAS_WRAPPER_DIR)`. `rc.d` files load after all
  `XONSHRC` files (xon.sh/envvars.html, xonsh 0.24.2 docs). Not verified by
  execution; the lexicographic sort scope is unverified.
- **elvish** has only `-rc`/`-norc`, and evaluating the user rc for this purpose
  is undocumented, so it stays `environmentOnly`.

macOS platform facts that shape the table:

- `/bin/sh` is Apple's trampoline to `/private/var/select/sh`, which is bash
  3.2.57 in POSIX mode. `shopt login_shell` is therefore false for bash-as-sh.
- `/bin/ksh` is ksh93 93u+ (default `ENV` is `~/.kshrc`).
- `/bin/csh` and `/bin/tcsh` are tcsh 6.21.00.
- `/etc/profile` and `/etc/csh.login` run `path_helper`, which REORDERS PATH.
  Environment-only PATH prepending therefore does not survive a login shell;
  this is why `environmentOnly` carries a notice instead of a guarantee.

Notices and residual limits:

- `environmentOnly` shows a soft notice: "Agent links are on. If your startup
  files change PATH, the claude and codex commands can start without Rafu."
- A genuine failure (a missing CLI or socket only) shows "Agent links are not
  available. Start a new terminal to try again." The old
  `BootstrapError.unsupportedShell` case is removed.
- `execName` on the bootstrap is `"-<basename>"` for nushell, xonsh, and
  `environmentOnly` (they get login behaviour from argv0) and nil for the
  others, which emulate login themselves. Used at
  `WorkspaceTerminalController.swift` (~line 1266).
- sh, dash, ksh, mksh, tcsh, and csh are not native login shells here: csh
  `logout` fails with "Not a login shell", and tcsh `~/.cshdirs` is not
  restored. A syntax error in a user startup file can stop the private file
  before its PATH line (same exposure bash already had). mksh, nu, xonsh, and
  elvish are unverified by execution.
- `CanvasTerminalBootstrapTests` covers the strategy table, per-strategy argv
  and environment, file contents and modes, and the no-leak rule, plus opt-in
  integration tests that really ran `/bin/sh`, `/bin/dash`, `/bin/ksh`, and
  `/bin/tcsh` against a fixture `HOME`. tcsh writes "no access to tty" and its
  prompt to stdout, so that test greps for a marker line.

## Host session variables must be scrubbed from bridge terminals

Verified on 2026-10-19 on the toolchain above. Claude Code inside a card
reported "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION…"
beside the development-channels notice, and channel pushes did not deliver
replies although the tools worked. Cause: Rafu Lightning had itself been
launched from inside a Claude Code session. `script/build_and_run.sh` uses
`/usr/bin/open -n`, which passes the caller's environment, so the app carried
11 host-session variables into the bridge environment.

`TerminalChildEnvironment.scrubbed(_:)` removes an EXACT list: `CLAUDECODE`,
`CLAUDE_PID`, `CLAUDE_EFFORT`, `CLAUDE_CODE_SESSION_ID`,
`CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXECPATH`,
`CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`,
`CLAUDE_CODE_BRIDGE_SESSION_ID`, and `CLAUDE_CODE_SESSION_ATTENDED`. It is
deliberately NOT a `CLAUDE_CODE_` prefix rule: user settings such as
`CLAUDE_CODE_USE_BEDROCK` (for example through `launchctl setenv`), every
`ANTHROPIC_*` variable, and `CLAUDE_CONFIG_DIR` must survive.

Ordinary (non-bridge) terminals pass `environment: nil` to SwiftTerm, which
builds a small fixed set (TERM, COLORTERM, LANG, plus LOGNAME/USER/DISPLAY/
LC_TYPE/HOME when present). They never inherit the app environment, so they
needed no scrub.

Open: whether the `server:rafu • no MCP server configured with that name`
warning is fully explained by these inherited variables is NOT yet confirmed by
the user. See "Claude dynamic MCP warning in 2.1.302" for the separate false
positive.

Unrelated diagnostic worth one line so nobody debugs it inside Rafu: Codex
reporting `Hook failed … exited with code 127` came from `~/.codex/hooks.json`
entries that run Cider's missing helper
(`~/Library/Application Support/Cider/Helpers/cider-events`). Exit 127 means
"command not found", not a Rafu bridge fault.

## Per-link states (macOS redesign; macOS build verification pending)

The session-wide "Enable Links" / "Pause Links" bar (`CanvasSessionLinksBar`) is
gone. `CanvasLinkStatusItem` replaced it, and state is now per link:

- States (`CanvasLinkState`): **Live**, **Paused**, **Disconnected(reason)**,
  **Failed(reason)**.
- A new terminal-to-terminal link starts **Paused**. This is a behaviour change:
  creating a link no longer makes it live. A restored link also starts Paused.
- Mapping implemented in `CanvasLiveBridge`: stopping a terminal gives
  Disconnected; a changed conversation gives Disconnected; a lost transport
  gives Disconnected; a refused send gives Failed until the next accepted
  message or a pause/resume.
- `CanvasLiveBridge` per-link API: `pause`, `resume`, `pauseAll(in:)`,
  `resumeAll(in:)`, `linkStates(in:)`, `linkState(of:in:)`, `activity(of:in:)`.
- Accepted-message events carry the connection, direction and date only. They
  carry no message body, so activity indicators cannot leak content. "Show
  Message Log…" was omitted because no log exists.
- Haptics: none for incoming agent messages (see
  [`canvas-interaction.md`](canvas-interaction.md)).

Evidence: pure logic only, compiled and tested outside the repo on a Linux
toolchain. The bridge was not run against Claude or Codex after this change, so
the live-exchange checks below must be repeated on a Mac.

## Reproduction and verification

Run focused CanvasBridge, CanvasCodexSession, and CanvasLiveBridge tests through
`./script/test.sh --filter Canvas`, then the full parallel and serial suites. SwiftTerm replaces its entire default
environment when an explicit environment array is supplied; the bootstrap must
merge inherited HOME/PATH and set TERM/COLORTERM. JSON paths used as TOML strings
must disable slash escaping: `\/` is not a valid TOML escape.
Launch only `./script/build_and_run.sh --verify` (Rafu Lightning).

Create two Canvas terminals. Run `claude` and `codex`. Accept only the provider's
visible channel/MCP consent. Connect the two nodes, then ask each CLI to list
Canvas connections. Ask Claude to send a short message to Codex and have Codex
reply through send_message. Check the same terminal conversations. Repeat while
busy, after pausing the link, after node removal, after /new, and in a second window.
Provider-backed model delivery must be recorded separately from fake transport
tests; source inspection alone does not prove a live exchange.

Related code: `RafuCore/CanvasBridge`, `CanvasLiveBridge`, `CanvasTerminalBootstrap`.
Related phase: `docs/plans/phases/workspace-canvas.md`.

## Additional lifecycle findings

A fully initialized Swift class runs deinit when its initializer later throws.
The Unix WebSocket client therefore has one descriptor owner in deinit; its
handshake error path must not also close the descriptor. A second close can
close an unrelated descriptor that another thread has just allocated.

Live edge permission uses the board object identity plus the edge UUID. Saved
board and edge UUIDs can be identical in two windows. A UUID-only permission set
would enable the second window by mistake. Weak board ownership prevents object
address reuse from inheriting permission. Removing or retargeting an edge
revokes permission before undo history changes; undo restores the line only.

## Codex conversation navigation

A loaded MCP session does not prove that the TUI still displays its thread.
Codex keeps side threads loaded, and unsubscribe does not evict a busy thread.
The TUI-only Unix WebSocket proxy therefore suspends the broker before forwarding
a navigation request or a message that identifies another thread. The original
protocol bytes are forwarded; no terminal text is read or stored. Frame and
message buffers are bounded to 256 KiB.

Suspension is permanent for that terminal capability. The broker rejects later
registration attempts and cancels and awaits pending queue processes before
acknowledging suspension. The proxy closes the transport if it cannot confirm
suspension. A provider can already have accepted a message before suspension;
that message cannot be recalled. Start a new terminal to restore the link.
Explicit resume/fork/agents commands use the normal CLI without a bridge.
Child-agent thread activity can suspend links conservatively. This limit is visible in the terminal status.

A native transport probe against installed Codex 0.163 also created, named,
and resumed the same empty thread through the proxy without a model turn.
The fake transport test checks that suspension occurs before `thread/start`
reaches the backend, while an initial resume of the bound thread stays connected.
Provider source: `codex-rs/tui/src/session_lifecycle.rs` and
`codex-rs/app-server/src/thread_lifecycle.rs` at `rust-v0.163.0`.

## Status reads must not change window state

During the live two-terminal check on 2026-10-18, Rafu Lightning stopped
responding. A three-second process sample showed the main thread repeatedly in
`CanvasTerminalSessionStatus.body`, `CanvasLiveBridge.status`, and
`WorkspaceWindowRegistry.sessionSnapshots`. The snapshot getter called a prune
operation that assigned the observed entries array on every read. The assignment
invalidated the view that had just read it, creating a continuous update loop.

Window snapshot queries must filter dead weak references without changing
observed registry state. Registration and removal own registry mutations.
A regression test tracks observation while reading the registry. Reproduce the
UI check by starting two Canvas terminals while one live provider is connected;
verify that menus, selection, and typing remain responsive.

After the fix, the three observation regression tests passed. The live repeat
started both Canvas terminals and created their session edge; the controls
remained responsive. Provider startup and model-message checks are separate
from this UI-loop check.


## Claude bridge flags are variadic

- Applies to: `CanvasBridgeLaunch.plan` (claude branch) and
  `claudeBridgeArguments(configPath:)` in
  `Sources/RafuCore/CanvasBridge/CanvasBridgeLaunch.swift`.
- Last verified: 2026-10-21, macOS 27.0 (Darwin 27.0.0), Claude Code 2.1.304.

Rule: pass Rafu's Claude flags as `--mcp-config=<path>` and
`--dangerously-load-development-channels=server:rafu`, one token each. Never
use the spaced form `--flag value`. The `=` form lets Rafu keep its flags as a
prefix and never moves, splits, or reads the user's arguments.

Why: Claude Code declares both options as Commander variadic options
(`--mcp-config <configs...>`, `--dangerously-load-development-channels
<servers...>`). In the spaced form, Commander gives the option every later
token up to the next token that starts with `-`. The old prefix
`--mcp-config <path> --dangerously-load-development-channels server:rafu`
followed by a positional prompt made the prompt a second channel entry.
Claude Code then exited at once with:

```text
--dangerously-load-development-channels entries must be tagged: Read the Rafu note titled "Local Keycloak – brief" (…) … Report to the coordinator terminal over the Rafu message link.
  plugin:<name>@<marketplace>  — plugin-provided channel (allowlist enforced)
  server:<name>                — manually configured MCP server
```

Launches whose first user argument was an option (for example `--resume`)
worked by chance. Codex is not affected: its `-c key=value` option takes one
value.

Evidence:

- Source, from the strings of the installed 2.1.304 executable. In
  Commander's `parseOptions`, the variadic capture is reset before each token.
  The `--name=value` branch emits one value and does not start a capture
  again. Claude Code's own argv scanners (the `u()` value lookup and the
  `iyt` settings scan) also accept `--mcp-config=<value>`.
- Real CLI, with no session and no inference. Each probe gives an untagged
  `--channels` entry, so Claude Code exits at its channel-tag check. The
  `--channels` check is not gated on print mode, and `--channels` is the same
  `<servers...>` option type. As a second safety net, the probe set
  `ANTHROPIC_BASE_URL=http://127.0.0.1:9` (a dead local port),
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, stdin from `/dev/null`, and a
  40-second alarm. Results:
  - `--channels bogus 'probe prompt "q" $(x)'` gives
    `--channels entries must be tagged: bogus, probe prompt "q" $(x)`. This
    reproduces the bug.
  - `--channels=bogus 'probe prompt …'` gives `… must be tagged: bogus`.
  - `--mcp-config <file> 'probe prompt …' --channels=bogus` gives
    `MCP config file not found: …/probe prompt "q" $(x)`. The spaced
    `--mcp-config` also takes the prompt.
  - `--mcp-config=<file> --channels=bogus 'probe prompt …'` and
    `--mcp-config=<file> --channels=bogus --add-dir /tmp /var -- '-dash prompt'`
    both stop at `… must be tagged: bogus`. The prompt stays positional.
  - `--add-dir /tmp /var --channels bogus` gives `… must be tagged: bogus`.
    An option token ends a variadic capture.
- Do not probe `--dangerously-load-development-channels` itself this way. Its
  tag check is skipped in print mode, so a non-TTY probe could go on to a
  session.

Not covered by this rule: an argument list that is malformed by itself.
For example, `--add-dir a b 'prompt'` gives the prompt to `--add-dir` in any
launcher, with or without Rafu.

Verification:

```bash
swift test --filter CanvasBridgeLaunchTests
```

`claudeBridgeFlagsNeverTakeAUserArgument` asserts the exact argument arrays
for a positional prompt (spaces, quotes, `$()`), a prompt with options,
`--resume`, a user `--` marker, and an empty list. It also replays
Commander's variadic rule on the result, and on the old spaced prefix.

## Claude dynamic MCP warning in 2.1.302

Verified on 2026-10-18 by inspection of the installed Claude Code 2.1.302
executable. A server supplied through `--mcp-config` can produce the startup
warning `server:rafu • no MCP server configured with that name`. The banner
checks only enterprise, managed, user, project, and local configuration scopes.
It does not check the dynamic configuration supplied through `--mcp-config`.

The actual notification gate is separate. It checks the server capability,
legacy protocol, provider availability, feature and organization policy, and
the opted-in channel name. Its server-name match uses the connected server's
name and the accepted development-channel entry; it does not require that
server to occur in the banner's configuration scopes. Accepting the development
channel dialog adds the entry with its development flag. Thus the banner alone
is not evidence that channel subscription failed. This is source verification,
not a live message-delivery result.

An upstream report describes the same false warning and reports successful
notification delivery on 2.1.295:
https://github.com/anthropics/claude-code/issues/100865 . The documented
`--dangerously-load-development-channels server:rafu` syntax remains correct:
https://code.claude.com/docs/en/channels-reference . Rafu sends the same entry
in the `=` form; see "Claude bridge flags are variadic".

Do not change user or repository MCP configuration to hide this warning. Check
`/mcp` in the running terminal to confirm that `rafu` is connected. If provider
debug logging is already enabled, the exact registration diagnostic is
`MCP server "rafu": Channel notifications registered`; a `Channel notifications
skipped:` diagnostic identifies a gate that actually declined registration.
Do not retain or print notification bodies while checking those diagnostics.
The Rafu connection status proves local bridge registration only. Claude login
and a live model response require separate checks. No inference request was
made for this investigation.

## Terminal click focus and Canvas selection

AppKit can make a native terminal first responder before its `mouseDown` runs.
An early return for an already-focused terminal skipped the Canvas callback.
Characters then went to the clicked terminal while Canvas shortcuts and paste
could still use the previous node. Always notify the host after a click leaves
the terminal first responder; call `makeFirstResponder` only when needed. A
native regression starts with that split state and checks selection, focused
card, and content mode after the click. The visible Focus button is an explicit
route to the same state, but ordinary content clicks must work too.


## Codex custom Unix endpoint is a symlink

Verified on 2026-10-18 with installed Codex CLI 0.163.0 on the toolchain and OS
listed above. `app-server --listen unix:///tmp/<private-directory>/socket`
publishes an owned symlink at the requested path. The actual Unix socket is
inside `/private/tmp/codex-daemon-<uid>`, whose owner is the current user and
whose permissions are 0700. `lstat` of the requested endpoint therefore reports
`S_IFLNK`; `stat` of its resolved target reports `S_IFSOCK`.

Readiness must accept this provider interface. The requested directory must
remain owned by the current user with permissions 0700. The link and its
resolved socket must have the same owner. The resolved socket's parent must
also be owned by the current user with no group or other permissions. It must
be within the requested private directory or directly below the root-owned,
sticky `/private/tmp` directory. This prevents another user from replacing an
otherwise private target parent through a public ancestor. The link must name a direct absolute socket target; only the system `/tmp` to
`/private/tmp` alias may occur in its parent path. Other intermediate symlinks
are rejected because another user could redirect them after validation. A link
to a regular file, a dangling link, or a socket in a public directory is not a
valid endpoint. Direct owned sockets remain valid for the transport fixtures.

A full supervisor PTY probe reproduced the startup failure after 15 seconds
without a model call. At two seconds the Codex process was running and the
endpoint existed. A bounded vnode watcher probe received the directory write
notification, but the old `S_IFSOCK` predicate rejected the symlink. This was
a validation failure, not a missing notification or slow provider startup.
The fix also rechecks the readiness predicate before reporting a timeout.

Reproduce without inference: start `codex app-server --listen unix://<private
path>`, inspect the endpoint with `lstat`, inspect its resolved socket and
parent, then stop that private server. Do not inspect or stop the shared daemon.
Run `./script/test.sh --filter CanvasCodexSession` for direct-socket, owned-link,
regular-file-target, and public-target-directory regression checks. The canonical
Rafu Lightning launch then checks the actual visible terminal route.

Related code: `CanvasCodexSession.socketIsOwned`, `validateEndpoint`, and
`CanvasCodexSessionTests`. Related decision and phase: ADR 0026 and
`docs/plans/phases/workspace-canvas.md`.

Provider source confirms the actual socket directory and direct target shape:
https://raw.githubusercontent.com/openai/codex/rust-v0.163.0/codex-rs/uds/src/daemon_directory.rs
and https://raw.githubusercontent.com/openai/codex/rust-v0.163.0/codex-rs/app-server-transport/src/transport/unix_socket.rs .

Foundation file-URL normalization is not a POSIX canonical-path check on macOS.
The native path probe showed that `standardizedFileURL` and
`resolvingSymlinksInPath()` can shorten `/private/tmp` to `/tmp`. Comparing that
result with a literal `/private/tmp` rejects the valid Codex endpoint. Endpoint
validation therefore uses `realpath` for canonical paths and frees its returned
buffer. It permits the system temporary-root alias and rejects other intermediate
symlinks. The actual-provider probe must use the production validation functions;
a transport-only probe with a placeholder validator cannot prove readiness.


## Codex startup reads other threads' metadata

Verified without inference on 2026-10-18 with installed Codex 0.163.0 and the
native TUI proxy. After reading and resuming the bound thread, the TUI sends
`thread/read` requests for other saved threads while it builds its history UI.
The requests omit `includeTurns` or set it to false. They do not select those
threads. Treating every different `threadId` as navigation suspends a new Canvas
connection before the user enters any input.

The proxy permits the read-only summary queries described here. A full-history read of
another thread, a different-thread resume, a new thread, unsubscribe, and unknown
operations keep the conservative suspension rule. Regression checks distinguish
startup metadata queries from actual thread selection and unknown operations.
The diagnostic probe records only whitelisted protocol method names, direction,
and identity-match booleans. It does not record thread IDs or message content.


The complete startup trace also found `thread/turns/list` requests for other
saved threads with `limit: 1` and `itemsView: null`. The versioned protocol uses
summary items when `itemsView` is null or omitted. `notLoaded` also excludes turn
items. These read-only forms are permitted. `full`, unknown item-view values,
and different-thread resume retain suspension. Regression checks include JSON
null explicitly; a Swift dictionary key with `NSNull` is present and is not nil.


## Visible startup and focus checks

Verified on 2026-10-18 in the canonical Rafu Lightning app, with Codex 0.163.0
and Claude Code 2.1.302. A plain `codex` command in a Canvas terminal opened the
interactive prompt and retained the `Codex connected` state through startup.
A plain `claude` command in the other terminal retained `Claude connected` after
the user-approved local channel consent. Both terminals remained interactive.
The restored edge began paused and became active only through the then-current
Enable Links control (since replaced by per-link resume; see "Per-link states").

A separate shell check clicked each terminal body, pasted a distinct `printf`
command, and pressed Return. Each terminal displayed only its own marker. The
selected card followed the clicked terminal. Starting the second terminal and
opening a second workspace window did not reproduce the snapshot observation
loop. The second window showed its independent welcome screen. These are
functional checks, not sustained performance measurements.

The live round-trip check then passed: Claude called the Rafu connection and
send tools, the existing visible Codex terminal received the request, Codex
called `rafu.send_message`, and the same Claude terminal displayed the channel
reply `CANVAS_ROUND_TRIP_OK`. No replacement conversation or managed run was
created. The first request required clarification because generic terminal
peers did not identify their provider; live peer metadata now includes the
verified provider so agents can select Claude or Codex directly. The test used
only a short marker request, with no repository content sent.

## Colour environment and named peers

Applies to Canvas shells prepared by `CanvasTerminalBootstrap`; verified on the
OS and toolchain above on 2026-10-18. The command runner sets `NO_COLOR=1`.
Passing the whole host environment to a PTY preserves that hint, so Claude and
Codex can suppress their own ANSI styles despite `TERM=xterm-256color` and
`COLORTERM=truecolor`. Remove inherited `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR`,
and `CLICOLOR_FORCE` before shell startup. User startup files run afterward and
can still set any of these values. Ordinary terminals already use SwiftTerm's
curated default environment. Do not force a CLI theme or rewrite its output.
The bootstrap tests cover inherited values and explicit zsh startup overrides.

A terminal card's Rename action sets its persisted display name. The bridge
exposes a normalized `@mention` alias and the live provider in connection
results. `send_message` accepts that alias or the existing exact card UUID.
Aliases resolve only among live authorized peers in the same Canvas. Duplicate
normalized names produce an ambiguity error; no arbitrary match is selected.
Renaming a card changes its alias while the UUID stays stable. Copy Mention in
the card menu and the Rename dialog show the same helper's spelling.

Mentions are interpreted by the connected agent through Rafu's tools. They do
not intercept terminal keystrokes or replace Claude/Codex native `@file`
completion. A file, app, or plain shell does not become an agent endpoint when
it is named or connected. Verify with the Canvas bridge and bootstrap test
suites, followed by the canonical Lightning launch and a named-peer exchange.

## Terminal node removal order

Verified by source tracing and lifecycle regressions on 2026-10-18. A confirmed
close-and-remove finalizes the terminal group before it removes the Canvas
card. Cleanup must not then call the group parking API with that deleted ID:
that raises `TerminalGroupValidationError.groupNotFound` (displayed as error 0).
Remove the card transaction first, release its presentation ownership, then
park only groups that still exist. Remove-only continues to keep the terminal
group. Deferred Canvas resource cleanup must also discard stale group owners
without parking missing groups. Tests in `CanvasNodeInteractionTests` cover
close-and-remove, remove-only, and deferred cleanup after group deletion.


## Connection drag coordinates

Applies to the Canvas connection handles added on 2026-10-18. A handle drag uses
an untransformed, named board coordinate space. Target hit testing subtracts
the viewport offset and divides by its scale, then checks cards in reverse
paint order. Preview drawing uses the same coordinates. The drag is transient
state: only a valid release on a different card edits the document. Escape,
self-drop, background-drop, and a removed source must leave connections alone.
The handle is separate from terminal input, card movement, and card resizing.
Its button action keeps a keyboard-accessible target chooser. Tests in
`CanvasConnectionDragTests` cover the pure transform and routing rules; the
native gesture order and target highlight require the Lightning UI pass.

## Codex large response streaming

Verified with Codex 0.163.0 on 2026-10-18: a no-inference startup probe received
an ordinary `app/read` response of 15,523,530 bytes. The previous 256 KiB frame
limit rejected it, closed the proxy transport, and left the TUI in its reconnect
loop. The server and TUI processes were still alive. This was not navigation.

Keep the 256 KiB buffered identity check for requests and notifications. A large,
final, unmasked incoming text frame may instead stream when its canonical
id-first `result` or `error` envelope matches an outstanding TUI request. The
response consumes that ID once. The pending set is bounded to 256 IDs, envelope
recognition to 4 KiB, transfer size to 64 MiB, and chunks to 8 KiB. The existing
partial-transfer deadline still applies. No full response tree or transcript is
stored. Unknown IDs, large notifications, and unsupported envelope shapes fail
closed. This fast path depends on the verified provider response serialization;
future provider changes need direct transport verification, not a wider blind
pass-through rule.

Transport loss and session navigation have separate fixed reason codes. A
transport failure must not report that the user changed sessions. Both revoke
message delivery; restarting the terminal creates a new capability. A successful
single exchange is insufficient evidence: verify startup with the actual app
catalog, idle time, and repeated exchanges. The focused Codex proxy tests cover
large responses, exact request identity, and rejected envelope forms.

The Swift Testing `#require` expansion cannot directly invoke the mutating
`CanvasConnectionDrag.finish` method: it captures the receiver as an immutable
closure parameter. Evaluate the mutation into a local optional first, then pass
that optional to `#require`. This was verified by the Swift 6.4 compiler while
building the drag regression. A syntax parse alone does not catch this error.

## Lightning follow-up UI evidence (2026-10-18)

The bundled Lightning app was launched with `script/build_and_run.sh --verify`.
In a separate test canvas, two ordinary terminals were renamed Planner and
Reviewer, then started with plain `claude` and `codex`. Both showed their native
CLI colours. Dragging a terminal link handle to the other terminal created a
session link; dragging it to a note created a Related edge, confirmed in List.
A third running shell node was closed and removed with Command-Shift-W and the
close confirmation. No TerminalGroupValidationError appeared, and the other
two sessions remained connected.

Claude sent to `@reviewer`, and Codex replied to `@planner` with NAMED_LINK_OK.
A later reverse request and direct reply delivered SECOND_LINK_OK in the same
visible sessions. Both sessions remained connected through startup, idle time,
and multiple turns. Claude's own auto-mode permission check declined one
channel-triggered reply; a direct authorized prompt sent it successfully. Rafu
must preserve that provider permission boundary. These checks do not prove
arbitrary network-failure recovery or every provider version.

## Paused-link diagnostics (verified 2026-10-18, macOS 27.0.1, Swift 6.4)

The message bridge reports `connected` as permission to deliver a message, not merely the presence of a running CLI. Peer responses also expose `linkState` (`live`, `paused`, `disconnected`, `failed`, or `related`). A paused edge must be resumed in Canvas. Restarting either terminal does not resume an edge. The MCP instructions explain this distinction; explicit sends to a paused peer return the same recovery step. No pause permission is bypassed. Older peer responses without this optional field still decode.

Evidence: the CC1 and Codex sessions changed from Paused to Live when the existing edge was resumed, without restarting either CLI. A real check then passed from Codex to CC1 and back through `send_message`, with `LINK_OK` visible in Codex. Claude’s startup channel notice alone did not establish a missing bridge. Check the current link state and MCP status before diagnosing startup failure. Regression coverage: `CanvasLiveBridgeTests.livePeerProviders` and `canvasPeerProviderRemainsCompatibleWithOlderResponses`; run `./script/test.sh --filter CanvasLiveBridgeTests` and `./script/test.sh --filter CanvasBridgeTests`. The edge badge uses intrinsic width within its text limit, so a short state label does not fill the hover width.

The restore notice derives its paused count from current bridge state. Only its dismissal is view state. Keeping the initial count in `@State` left a paused banner visible after an individual link was resumed. `WorkbenchChromeRedesignTests.canvasLinkStatusLayout` guards the observation boundary and compact badge layout.
