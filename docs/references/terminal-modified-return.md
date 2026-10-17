# Modified Return in the embedded terminal

- Applies to: Rafu Lightning's native SwiftTerm input, including ordinary shells,
  Agent Terminals, and Ensemble terminal panes.
- Last verified: Swift 6.4, macOS 27.0.1, SwiftTerm 1.14.0, 2026-10-17.
  Four focused tests passed. A native Lightning terminal probe recorded
  Shift-Return `0A`, Control-Return `0A`, and Return `0D`, exactly once each.
  The test used a second workspace window and started no agent. The probe
  restored its terminal attributes and its shell exited normally.

## Rule

When no extended keyboard protocol is active, Shift-Return, Control-Return, and
Control-Shift-Return send one LF byte (`0A`, the same input as Control-J).
This includes keypad Enter. Plain Return keeps SwiftTerm's CR (`0D`).
Command and Option combinations, other keys, marked-text composition, and all
negotiated Kitty keyboard events remain with SwiftTerm. Do not force the Kitty
mode flag, emit a fake pasted prompt, insert a backslash, or inspect process names
to select a vendor-specific mapping.

The CLI owns the meaning of input. LF is a newline command in Claude Code;
it may submit a shell command or have another binding in other applications.
When a CLI negotiates Kitty, Shift-Return and Control-Return retain distinct
protocol encodings and the CLI's own keybindings decide their meaning. Rafu
must not replace a negotiated binding with a global newline shortcut.

## Verified source behavior and bridge

SwiftTerm's legacy `keyDown` handles Control characters before text input;
plain/Shift Return otherwise goes through `interpretKeyEvents` and
`doCommand(insertNewline:)`, which sends CR. The modifier can be lost before
PTY delivery. SwiftTerm's `keyDown` override is public but not open; an external
subclass override fails compilation. `viewDidMoveToWindow` is open.

`TerminalNewlineMonitor` installs one application-local key-down monitor while
at least one Rafu terminal view is attached. It routes only to the event
window's visible terminal first responder, outside attached sheets and modal
windows. It does not read keystrokes from other applications, buffer text, or
retain a window/view. Registration uses object identities. Detach and isolated
main-actor deinitialization remove registration; the last removal removes the
monitor. The synchronous AppKit callback and registry stay on the main actor.
Only a handled modified Return is consumed; other events pass through unchanged.

The byte travels through SwiftTerm's public `send` method and existing PTY
path. There is no process start, background task, extra command, logging of
input, dependency patch, or provider credential access in this change.

## Verification

`TerminalNewlineTests` checks exact LF bytes for main/keypad Return, exact CR for
ordinary Return, modifier exclusions, composition, key-up, window isolation,
visibility, nonterminal focus, registration cleanup, negotiated Kitty encodings,
and protocol reset. The byte delegate exists only in tests; production keeps
SwiftTerm's process delegate.

```sh
./script/test.sh --filter TerminalNewlineTests
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
./script/test.sh --no-parallel
./script/build_and_run.sh --verify
```

For the native input pass, run a disposable local raw-terminal reader from a
Lightning terminal. Press Shift-Return, Control-Return, and Return. Expect `0A`,
`0A`, and `0D`, each once. Restore the terminal attributes in a `finally` block.
Do not type a test prompt into a live agent or log unrelated terminal content.
Test a second window and a nonterminal field. Confirm that native IME input and
application-defined Kitty shortcuts remain available. Do not claim every CLI
uses the same newline binding from the byte tests alone.

## Sources and related work

- [Claude Code terminal configuration](https://code.claude.com/docs/en/terminal-config):
  Control-J is a newline command without terminal setup.
- [Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/):
  applications opt into enhanced key reporting.
- SwiftTerm: `Mac/MacTerminalView.swift`, `Apple/AppleTerminalView.swift`,
  `KittyKeyboardEncoder.swift` at the revision in `Package.resolved`.
- `Terminal/RafuTerminalView.swift`, `Terminal/TerminalNewlinePolicy.swift`.
- ADR 0004, ADR 0023; [Terminal Groups phase](../plans/phases/terminal-groups.md).
