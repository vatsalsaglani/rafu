# GUI-launched apps inherit launchd's PATH, not your shell's

- **Applies to:** any Rafu code that locates an external CLI on the user's
  Mac — today every Ensemble adapter, and `gh`/`git`/language-server
  discovery if it ever grows the same shape.
- **Last verified:** 2026-07-25, macOS 26 (Darwin 25.5.0), Swift 6.2.

## The rule

`ProcessInfo.processInfo.environment["PATH"]` inside a Finder-launched (or
`open`-launched) `.app` is **launchd's minimal PATH**:

```
/usr/bin:/bin:/usr/sbin:/sbin
```

It is NOT the user's login-shell `PATH`. Your `~/.zshrc` never runs. Anything
installed by a version manager (nvm, fnm, volta, asdf, n, nodenv), by Bun, by
Yarn/npm global prefixes, or by Homebrew on Apple Silicon
(`/opt/homebrew/bin`) is therefore invisible to `which` run from inside the
app — while resolving perfectly when you check by hand in Terminal.

**Two failure shapes follow, and Rafu hit both.**

1. **Search only the inherited PATH → find nothing.** The CLI is installed;
   the app reports it missing.
2. **Prefer the inherited PATH over a curated fallback → find *less* than
   intended.** Code shaped like

   ```swift
   let searchPath = ProcessInfo.processInfo.environment["PATH"]
       ?? RafuConductorEnvironment.curatedPath   // ← almost never reached
   ```

   looks like a safe fallback, but the environment key is always *present*
   under launchd, so the curated value is dead code in exactly the situation
   it exists for. The nil-coalescing operator is the bug: the host PATH is
   non-nil and useless.

## Why it matters

This produces a flatly dishonest UI. Rafu's Settings → Agents row said
**"Cline — Not found on this Mac. Install the CLI to use it in a run."**
while `cline --version` printed `3.0.46` in the user's terminal, because
Cline lives at `~/.nvm/versions/node/v22.0.0/bin/cline`. ADR 0018 stakes the
whole Ensemble on honest capability reporting, so a false negative here is a
product-level defect, not a cosmetic one.

It is also invisible to normal development: `swift test` and `swift run`
inherit your shell's rich PATH, so every headless test passes and every
manual check from a terminal succeeds. It only reproduces in the staged
`.app`, which is why `./script/build_and_run.sh` is the required verification
for anything touching discovery.

## The fix in Rafu

`RafuConductorEnvironment` (`Sources/RafuApp/Conductor/ConductorCore.swift`)
gained two members:

- `versionManagerBinDirectories` — enumerates per-version directories
  (`~/.nvm/versions/node/*/bin`, fnm, n, nodenv) newest-name-first, plus
  fixed ones (volta, asdf, bun, deno, yarn global, npm-global), dropping
  anything that does not exist.
- `discoverySearchPath(hostSearchPath:)` — host PATH **+** curated entries
  **+** version-manager directories, deduplicated, absolute components only.
  A union, never a replacement, so a shell-launched Rafu keeps everything it
  already had.

All four adapter families now discover through it (`ClaudeCodeAdapter`'s
`discoverySearchPath`, `C3AdapterProcess.resolveExecutable`, and the Gemini
and Cursor `combinedPath`s).

## The invariant this must NOT break

**Widening where Rafu LOOKS is not the same as widening what a child
INHERITS.** ADR 0018 requires a minimal, explicit, non-inherited child
environment. So:

- `curatedPath` (what children get) is **unchanged**.
- `discoverySearchPath` is used **only** to locate an executable.
- A child still receives `curatedPath`, plus at most the parent directory of
  the executable the adapter actually resolved — the existing documented
  adapter rule in
  [`conductor-pty-spawn-and-child-environment.md`](conductor-pty-spawn-and-child-environment.md).

`childEnvironmentStaysCurated` in
`Tests/RafuAppTests/Conductor/ExecutableDiscoveryPathTests.swift` asserts a
child's `PATH` contains no version-manager directory, so the two concerns
cannot silently merge later.

## Reproduction

```bash
# What the GUI sees (fails):
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" /usr/bin/which cline
# → exit 1

# What discovery now searches (succeeds):
env -i PATH="$HOME/.nvm/versions/node/v22.0.0/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin" \
    HOME="$HOME" /usr/bin/which cline
# → /Users/<you>/.nvm/versions/node/v22.0.0/bin/cline
```

Confirm the app's own view with `launchctl getenv PATH` — empty output means
launchd is using its built-in default, which is what your `.app` gets.

## Verification

```bash
swift build                       # 0 warnings
swift test --filter ExecutableDiscoveryPath
./script/build_and_run.sh --verify   # REQUIRED: only the staged .app reproduces this
```

Then check Settings → Agents shows every installed CLI as found.

## Related

- ADR 0018 (honest capability reporting; minimal child environment)
- [`conductor-pty-spawn-and-child-environment.md`](conductor-pty-spawn-and-child-environment.md)
  (the child's missing `PATH` and the prepend-the-executable's-directory rule)
- [`conductor-adapter-opencode-cline-kimi.md`](conductor-adapter-opencode-cline-kimi.md)
  (C3 adapters, where this surfaced)
