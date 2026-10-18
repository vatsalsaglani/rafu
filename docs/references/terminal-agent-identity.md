# Terminal agent identity (typed `claude` / `codex` in a shell)

- Applies to: `Sources/RafuApp/Terminal/TerminalForegroundProcess.swift`
  (foreground sampling, classifier, identity state, Darwin inspector),
  `Sources/RafuApp/Support/AgentIdentity.swift` (`resolvedAgentProvider`,
  `presentedTitle`, process-name matching),
  `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift` (sampling
  triggers, reset), `TerminalSessionPresentation.title` /
  `agentTitle` / `isGenericTitle` in `Terminal/TerminalsPanelModel.swift`, and
  the surfaces that show a terminal name: editor tab strip (terminal tab,
  Terminal Group tab, overflow menu), tab switcher, Terminals panel, notch
  rows, Ensemble terminal node header.
- Last verified: Swift 6.2 Linux toolchain (swift.org ubuntu24.04), Ubuntu
  24.04, 2026-10-18. Pure logic only (scratch SwiftPM package, 16 Swift
  Testing tests with 54 cases, default `MainActor` isolation, no warnings).
  The three controller tests, the Darwin calls, and the SwiftUI surfaces are
  not yet compiled or run on a Mac.

## Observation

When the person types `claude` or `codex` in a login shell, the terminal
title is not a stable identity:

1. The shell's `preexec` sets the title to the command ("claude"). The old
   title-only detection showed the agent icon.
2. The agent CLI then replaces the OSC 0/2 title with its own text
   ("✳ Fix tests") or clears it. Detection failed, and the tab fell back
   to the shell name, "Terminal" (Ensemble node default title), or
   "Terminal Group N".

`agentProvider` is set only when Rafu launched the agent from a process
spec, so it did not help.

## Rule

Resolution order (`TerminalAgentResolution.resolve`):

1. `agentProvider` (Rafu launched the agent).
2. Hook signal: a live `AgentActivityStore` session matched to this terminal
   by PID chain (or folder). Hook matching itself uses
   `observedAgentProvider` (no hook step), so the two never recurse.
3. Foreground process (`TerminalAgentIdentityState.foreground`).
4. Sticky title: a title that named an agent is remembered and is kept when
   the title later changes or clears.
5. The current title (only while the process has not exited).

Clearing:

- The foreground returns to the shell → the sticky title clears, and a
  stale title that still says "claude" no longer counts.
- The process exits, or the terminal is closed or restarted → all observed
  state resets.
- Another non-agent program in front (`.other`) keeps the sticky title: an
  unrecognised launcher must not erase a good title match.

Foreground sampling:

- `tcgetpgrp` on the PTY primary descriptor (`LocalProcess.childfd`, public
  in SwiftTerm 1.14.0). tmux uses the same call on macOS
  (`osdep-darwin.c`). It runs on the main actor while the view owns the
  descriptor: one non-blocking `ioctl`, and reading the descriptor on another
  thread could race its close and reuse.
- Group leader equal to `shellProcessID` → shell. Otherwise the leader is
  described off the main actor (`@concurrent`
  `TerminalForegroundProbe.classify`): `proc_name`, `proc_pidpath`, and at
  most 4 leading argv strings from `KERN_PROCARGS2` (buffer `kern.argmax`,
  capped at 4 MiB; the environment block is never parsed). The result is
  cached per group leader PID.
- Triggers: a title change and an output burst (coalesced, 600 ms), then a
  3 s tick while a program other than the shell is in front. A hidden
  terminal keeps the tick for 30 s after its last output. Only ordinary login
  shells sample: a spec-backed process (Agent Terminal, Ensemble role) is its
  own group leader, so "leader == `shellProcessID`" would misread it as a
  shell prompt and clear a correct identity.
- Nothing logs a process name, path, or argv.

Process-name mapping (`AgentIdentityMatcher.match(processName:executablePath:arguments:)`):
process name, then executable file name, then `argv[0]`, then for an
interpreter (`node`, `bun`, `deno`, `python`, `env`, `sh`/`bash`/`zsh`, …)
the first operand: script stem (`codex.js` → codex), the package after
`node_modules` (`@anthropic-ai/claude-code/cli.js` → Claude Code), or a
hyphenated product directory (`cursor-agent`, `gemini-cli`) in the path.
The native Claude Code installer runs a binary named by version
(`~/.local/share/claude/versions/2.0.14`); `argv[0]` (`claude`) names it.

Title presentation (`TerminalSessionPresentation.title`): a user-set name
always wins. With an agent, a generic title (empty, only glyphs, "Terminal",
the shell name, the "zsh 2" fallback, a path, or only the agent's own name)
shows the agent's display name; a meaningful title (a task name) is shown
as is. Ensemble nodes and Terminal Group tabs apply it only while their own
name is automatic (`TerminalNaming.isAutomaticGroupName`).

## Why it matters

The identity is shown on every terminal surface. Losing it mid-run made
two different agents look like two plain terminals.

## Known limits

- `npx codex`, or any launcher whose group leader is a generic process that
  then spawns the agent as a child, classifies as `.other`; the sticky title
  and hooks still apply. Child-process walking was not added.
- The cache is per PID: a process that `exec`s a different program keeps its
  first classification until the shell is in front again.

## Verification

```bash
swiftc -parse -swift-version 6 Sources/RafuApp/Terminal/TerminalForegroundProcess.swift
swift test --filter TerminalAgentIdentityTests
./script/build_and_run.sh --verify   # then type `claude` and `codex` in two terminals
```

Manual Mac check (pending): in two shells start `claude` and `codex`; the
tab, Terminals panel row, notch row, and an Ensemble terminal node keep the
vendor mark and show "Claude Code" / "Codex" or the agent's task title; on
exit to the prompt the mark clears within one sample.

## Related

- `docs/references/agent-hooks-and-now-playing.md` (hook PID-chain matching)
- `docs/references/agent-terminals.md` (Rafu-launched agent terminals)
- `Tests/RafuAppTests/TerminalAgentIdentityTests.swift`
