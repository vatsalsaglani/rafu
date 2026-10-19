# 0028. Agent links on non-native shells use login emulation, HOME forwarding, or environment-only with a notice

- Status: Accepted
- Date: 2026-10-19

## Context

An Ensemble terminal card gets agent links by starting its shell with a private
wrapper directory first on PATH, so `claude` and `codex` run through Rafu's
wrappers and reach the MCP bridge. `CanvasTerminalBootstrap.prepare` accepted
only zsh and bash. Every other shell started without the bridge environment and
without the wrapper directory, so the plain binaries ran: links showed
"Disconnected" and Claude Code in that card had no Rafu MCP tools. The only
explanation lived in the links popover and was easy to miss. The Ensemble shell
picker (ADR 0023 amendment, 2026-10-19) made fish cards common, and the user then
asked for the other shells too.

Two platform facts constrain the design. `/etc/profile` and `/etc/csh.login` run
`path_helper`, which reorders PATH, so prepending the wrapper directory in the
spawn environment alone does not survive a login shell. And for POSIX shells the
obvious form — `ENV=<private file>` with `-l -i` — fails whenever the user's
`~/.profile` sets `ENV`, because the profile runs first and overrides it, so the
private file never runs (proven for `/bin/sh`, `/bin/dash`, `/bin/ksh`).

## Decision

`CanvasShellBridgeStrategy` selects a mechanism per shell basename, and
`supportsBridge(shellBasename:)` means "wrapper PATH order is guaranteed after
the user's startup files":

- zsh keeps ZDOTDIR forwarding; bash keeps `--noprofile --rcfile` with a private
  rc that runs the login files.
- fish uses `--init-command`, which runs after `config.fish` and `conf.d`.
- sh, dash, ksh, and mksh drop `-l`, take `ENV=<private>/env.sh`, and **emulate**
  the login sequence inside that private file after restoring the user's own
  `ENV` (carried in `RAFU_CANVAS_USER_HAD_ENV` / `RAFU_CANVAS_USER_ENV`).
- tcsh and csh forward `HOME`: `HOME` is the private directory,
  `RAFU_CANVAS_USER_HOME` is the real one, and the private `.tcshrc` restores
  `HOME` and then runs the real startup sequence before setting PATH.
- nu and xonsh use their documented post-config hooks (`-e`, `XONSHRC_DIR`
  `rc.d`).
- elvish and any unknown basename are `environmentOnly`: PATH is prepended in
  the spawn environment with no startup hook, and the card carries a soft
  notice that startup files may still change PATH. `BootstrapError.
  unsupportedShell` is removed; a failure notice now means only a missing CLI or
  socket.

Separately, `TerminalChildEnvironment.scrubbed(_:)` removes an exact list of
host Claude Code session variables from the bridge environment, because
`open -n` passes the launching session's environment into the app.

Every inline command is a static literal that reads environment variables at run
time; private files contain only static text; paths reach shells only through
environment variables; the private directory is 0700 and its files 0600.

## Alternatives considered

- **Native `-l` with a private `ENV`.** Rejected: the user's `~/.profile`
  overrides `ENV`, so the private file never runs. This was measured, not
  assumed.
- **Editing the user's own rc files** to add the wrapper directory. Rejected:
  Rafu must not modify user startup files, and the change would outlive the
  terminal.
- **Replacing `HOME` or the XDG config directories for all shells.** Rejected
  as a general mechanism; it changes history, caches, and plugin state. It is
  used only for the csh family, where no other documented hook exists, and only
  until the private rc restores `HOME`.
- **Evaluating the user rc under elvish's `-rc`.** Rejected: elvish offers only
  `-rc`/`-norc`, and chaining the user's rc this way is undocumented.
- **Blocking agent links on unsupported shells** (the previous behaviour).
  Rejected: environment-only PATH usually works and an honest notice is better
  than refusing.
- **A `CLAUDE_CODE_` prefix scrub.** Rejected: it would delete legitimate user
  settings such as `CLAUDE_CODE_USE_BEDROCK`.

## Consequences

- Agent links now work on far more shells, but with different guarantees: the
  notice distinguishes guaranteed PATH order from best effort.
- Emulated login shells are not native login shells. csh `logout` fails with
  "Not a login shell", tcsh `~/.cshdirs` is not restored, and `shopt
  login_shell` is false for bash-as-sh.
- A syntax error in a user startup file can stop the private file before its
  PATH line (the exposure bash already had).
- mksh, nu, xonsh, and elvish are unverified by execution and need a check on a
  machine that has them.
- `execName` is `"-<basename>"` only for nushell, xonsh, and `environmentOnly`,
  which take login behaviour from argv0.

## Revisit trigger

A shell changes its startup order or adds a documented post-config hook (notably
elvish), or an execution check on nu, xonsh, mksh, or elvish contradicts the
table.

## Related plan, reference, and implementation paths

- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
- Reference: [`../references/canvas-live-sessions.md`](../references/canvas-live-sessions.md)
  ("Per-shell bridge strategies", "Host session variables must be scrubbed"),
  [`../references/terminal-signals-and-shell-catalog.md`](../references/terminal-signals-and-shell-catalog.md)
- Related decisions: [`0026-canvas-live-session-links.md`](0026-canvas-live-session-links.md),
  [`0023-terminal-groups-and-saved-layouts.md`](0023-terminal-groups-and-saved-layouts.md)
- Code: `Sources/RafuApp/Canvas/Integration/CanvasTerminalBootstrap.swift`,
  `Sources/RafuApp/Terminal/TerminalChildEnvironment.swift`,
  `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`
