# Terminal engine signals, shell catalog, and notification plumbing

- Applies to: `Sources/RafuApp/Terminal/` (`WorkspaceTerminalController.swift`,
  `RafuTerminalView.swift`, `TerminalShellCatalog.swift`,
  `PreferredShellStore.swift`, `TerminalAttentionNotifier.swift`)
- Last verified: Swift 6.2 / macOS 26 / SwiftTerm 1.14.0 / 2026-07-21

## Rule or observed behavior

**SwiftTerm delegate signal inventory.** `LocalProcessTerminalViewDelegate`
(the delegate `WorkspaceTerminalController`'s `DelegateProxy` implements)
exposes exactly four members: `sizeChanged`, `setTerminalTitle` (OSC 0/2,
drives `reportedTitle`), `hostCurrentDirectoryUpdate` (OSC 7, drives live
cwd), and `processTerminated(source:exitCode: Int32?)` — `exitCode` is
optional because a process killed via `shutdown()` (explicit close) has no
real exit status to report, only a natural exit does.

**The bell signal does NOT reach this delegate — it is a separate, easy-to-miss
seam.** `LocalProcessTerminalViewDelegate` has no `bell` member at all. BEL
instead reaches `TerminalView.bell(source: Terminal)`
(`Mac/MacTerminalView.swift:2803` in SwiftTerm 1.14.0), an `open` method
whose only built-in behavior is forwarding to
`TerminalViewDelegate.bell` (default implementation: `NSSound.beep()`).
`LocalProcessTerminalView` sets `terminalDelegate = self` internally and
never forwards bell onward to `LocalProcessTerminalViewDelegate` — there is
no delegate property to assign. The fix is a subclass override, not a
delegate hookup: `RafuTerminalView: LocalProcessTerminalView` overrides
`bell(source:)` directly, calling `super.bell(source:)` first to preserve
the system beep, then invoking its own `onBell` closure.

`TerminalViewDelegate.bell`'s default implementation cannot be overridden
by conforming a subclass to a different default — it is a **protocol
extension default**, statically (not dynamically) dispatched. Only
overriding the `open` `TerminalView.bell(source:)` method itself, at the
class level, intercepts the call.

`nonisolated override func bell(source: Terminal)` must wrap its body in
`MainActor.assumeIsolated`, and must NOT forward the incoming `source`
parameter directly into that closure — it arrives task-isolated to the
`nonisolated` override, and the compiler refuses to send a non-`Sendable`
`Terminal` across the boundary even though the call is synchronous and
main-thread-only in practice. Re-fetch the same instance via
`getTerminal()` from inside the already-isolated closure instead (there is
exactly one `Terminal` per `TerminalView`, so `source` and `getTerminal()`
are identical here).

**Bounded viewport read recipe (the only sanctioned way to read terminal
content).** `Terminal.getLine(row:)` returns a `BufferLine`; call
`.translateToString(trimRight:characterProvider:)` with
`terminal.getCharacter(for:)` as the character provider, iterating rows
`0...topRow` where `topRow` is clamped to the cursor row (viewport-relative
only, never full scrollback). `Terminal.getBufferAsData` is FORBIDDEN for
this purpose — it walks the entire scrollback buffer unbounded and has no
place in a feature meant to read only "what's currently on screen."

**`/etc/shells` parsing rules and the curly-quote case.**
`TerminalShellCatalog.parseEtcShells` treats `#` as starting a
whole-line-or-trailing comment, trims whitespace, and keeps only lines that
still start with `/` after trimming — deliberately naive, no
quoting/word-splitting. A real-world `/etc/shells` line on the verification
machine contains CURLY SMART QUOTES around a path
(`“/usr/local/bin/fish”`); after trimming, that line no longer starts with
`/` (it starts with the smart-quote character), so it is correctly dropped
rather than misparsed into a bogus executable path. Reproduced in
`TerminalShellCatalogTests`.

Discovery never spawns or executes anything to probe a candidate shell —
only `FileManager.isExecutableFile(atPath:)` and file existence. The
`$SHELL` entry is exempt from the executability filter and always kept
first, so the catalog is never empty even if `$SHELL` itself is stale.
Login-argument selection (`-l`) is a per-basename ALLOWLIST
(`zsh`/`bash`/`sh`/`ksh`/`fish`/`tcsh`/`csh`), not a denylist — an unknown
shell given an unsupported `-l` flag may abort outright, while omitting the
flag for a shell that does support it only means "not started as a login
shell" (argv[0] already carries the leading `-` that some shells use to
detect login mode independent of `-l`).

**`UserDefaults` is not `Sendable` on this SDK.** Any `nonisolated
Sendable` store that needs `UserDefaults` (e.g. `PreferredShellStore`,
matching the earlier `WorkspaceSearchHistoryStore` pattern) must store the
SUITE NAME (`String?`) and construct `UserDefaults(suiteName:)` on demand
inside a computed property, never hold a `UserDefaults` instance as a
stored property — the latter breaks the type's honest `Sendable`
conformance.

**`UNUserNotificationCenter` requires real bundle identity and code
signing.** A raw SwiftPM executable or the `swift test` binary has no
bundle identity; constructing/using `UNUserNotificationCenter.current()`
against one is known to fail or trap. All `UserNotifications` framework
usage must sit behind one protocol seam (`TerminalAttentionNotifying`) so
tests inject a spy and never construct the real
`SystemTerminalAttentionNotifier`. Separately, an UNSIGNED `.app` bundle
cannot post user notifications on current macOS even with bundle
identity — `script/build_and_run.sh` now ad-hoc signs the staged bundle so
notification posting works under the canonical launch/verify script.

## Why it matters

The bell-forwarding gap is invisible from the delegate protocol surface —
implementing every method of `LocalProcessTerminalViewDelegate` still
produces a terminal that never reports BEL, because the signal never
reaches that protocol at all. Anyone extending terminal attention/status
signals needs to know the delegate protocol is incomplete for this one
signal and where the real hook is. The viewport-read/`getBufferAsData`
distinction is a deliberate privacy/memory boundary (AGENTS: bounded reads
only, never full-scrollback content capture) and is easy to violate by
reaching for the more "complete-looking" API. The `/etc/shells` and
`UserDefaults`-Sendable notes prevent regressions in code that looks
correct until it meets real machine data or a strict-concurrency build. The
notification bundle-identity/signing notes prevent "it doesn't work in
tests" and "it doesn't work under the canonical run script" debugging
loops.

## Reproduction or evidence

- SwiftTerm 1.14.0 source: `Mac/MacLocalTerminalView.swift`
  (`LocalProcessTerminalViewDelegate` — four members only, no `bell`);
  `Mac/MacTerminalView.swift:2803` (`open func bell(source: Terminal)`,
  default forwards to `TerminalViewDelegate.bell`).
- `/etc/shells` curly-smart-quote line, reproduced as a
  `TerminalShellCatalogTests` fixture case; dropped because the trimmed
  line no longer has a `/`-prefix.
- `WorkspaceTerminalController.swift:449-466` (`DelegateProxy`): all four
  real delegate callbacks hop `nonisolated` → `MainActor.assumeIsolated`.
- `RafuTerminalView.swift`: `bell(source:)` override and
  `recentOutputSnippet(maxLines:maxBytes:)`.

## Verification

- `swift build` — 0 warnings.
- `swift test` and `swift test --no-parallel` — 956 tests green, including
  `TerminalShellCatalogTests`, `TerminalEditorTabTests`, and the
  attention/bell test suites.
- `grep -rn "import UserNotifications" Sources/` — exactly one match
  (`TerminalAttentionNotifier.swift`).
- `./script/format.sh --lint` — clean.

## Related code, ADRs, and phases

- `Sources/RafuApp/Terminal/RafuTerminalView.swift`
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`
- `Sources/RafuApp/Terminal/TerminalShellCatalog.swift`
- `Sources/RafuApp/Terminal/PreferredShellStore.swift`
- `Sources/RafuApp/Terminal/TerminalAttentionNotifier.swift`
- `Sources/RafuApp/Services/WorkspaceSearchHistoryStore.swift` (the earlier
  `UserDefaults`-suite-name pattern this mirrors)
- Plan: [`terminal-manager.md`](../plans/phases/terminal-manager.md)
- ADRs: [`0004-embedded-terminal.md`](../decisions/0004-embedded-terminal.md)
  (amended), [`0014-terminal-as-editor-tab.md`](../decisions/0014-terminal-as-editor-tab.md)
  (amended), [`0016-terminal-attention-notifications.md`](../decisions/0016-terminal-attention-notifications.md)
