# CLI → app location (exec path & symlink install)

- Applies to: `rafu <path>` folder opening, `LauncherAppLocator`, `CLIInstaller`
- Last verified: Swift 6.2, macOS 14+ (Darwin 25.1), 2026-07-17

## Rule or observed behavior

To open a folder, the `rafu` CLI must find the `Rafu.app` that encloses it and
run `open -a <bundle> <folder>`. Getting there depends on two things that are
easy to get wrong:

1. **Do not use `CommandLine.arguments.first` (`argv[0]`) to find the running
   executable's path.** When a binary is invoked bare through `PATH`
   (`rafu .`), the shell sets `argv[0]` to the *basename* (`"rafu"`), not a
   resolvable path. `URL(fileURLWithPath: "rafu").resolvingSymlinksInPath()`
   then resolves against the current directory and fails. Use
   `_NSGetExecutablePath()` (Darwin) instead: the kernel exec's the fully
   resolved path even when `argv[0]` is a basename, and that is what
   `_NSGetExecutablePath()` reports — including a `~/.local/bin/rafu` symlink.
   Two-call size-probe form:

   ```swift
   var size = UInt32(0)
   _ = _NSGetExecutablePath(nil, &size)          // sets required size
   var buffer = [CChar](repeating: 0, count: Int(size))
   guard _NSGetExecutablePath(&buffer, &size) == 0 else { /* fall back */ }
   ```

2. **Install the CLI as a symlink into the bundle, not a copy.** The locator
   finds the bundle by walking four path components up from the CLI
   (`Rafu.app/Contents/SharedSupport/bin/rafu`). A plain copy in `~/.local/bin`
   has no bundle above it, so the walk-up returns nil and the CLI can never open
   the app. A symlink is followed by `resolvingSymlinksInPath()` back into the
   bundle, so the walk-up succeeds. The symlink also auto-tracks app rebuilds,
   eliminating the "stale copy until manual reinstall" failure.

`CLIInstaller` replaces an existing symlink **or** a regular file (the old
copy) at the destination, detecting the symlink without following it (via
`URLResourceValues.isSymbolicLink`) so a *dangling* link from a moved bundle is
still cleaned up. `FileManager.fileExists(atPath:)` follows symlinks and reports
`false` for a dangling one, so it cannot be the sole existence check. A
directory (or anything else) at the destination is refused, not clobbered.

## Why it matters

Both bugs shipped together in commit `c3b3ed0` and made the advertised
`rafu <path>` feature fail for every normally-installed CLI: the copy install
guaranteed the locator returned nil, and even a hand-made symlink failed because
the locator trusted `argv[0]`. A user with a months-old copy saw a since-removed
"app IPC is not implemented" message, because a copy never updates on rebuild.

## Reproduction or evidence

- Before the fix: `rafu .` (bare, via PATH) → "could not locate Rafu.app";
  invoking the same binary by absolute path succeeded (because `argv[0]` was
  then a real path). This is the tell that `argv[0]` — not the install — is the
  locator bug.
- After the fix: `( cd /usr && rafu <dir> )` and `( cd <dir> && rafu . )` both
  print "Opening <dir> in Rafu." and exit 0.
- `Tests/RafuCoreTests/LauncherArgumentParserTests.swift` —
  "enclosingAppBundle follows a ~/.local/bin symlink back into the bundle"
  (resolved symlink → bundle; raw symlink path → nil).
- `Tests/RafuAppTests/CLIInstallerTests.swift` — symlink creation, replacing a
  stale regular-file copy, replacing a dangling symlink, refusing a directory,
  and the missing-source error.
- Path normalization caveat in tests: the temp dir under `/var/folders/…`
  resolves to `/private/var/…`, so compare bundle paths after
  `resolvingSymlinksInPath()` on both sides.

## Verification

- `swift build`; full `swift test` (505 tests); `./script/format.sh --lint`
- `./script/build_and_run.sh` then bare `rafu <dir>` from an unrelated cwd —
  opens the folder.

## Related code, ADRs, and phases

- **Code**: `Sources/RafuCore/Launcher/LauncherAppLocator.swift`
  (`enclosingAppBundle`, `currentExecutablePath`),
  `Sources/RafuApp/Services/CLIInstaller.swift`, `Sources/RafuCLI/main.swift`
- **Tests**: `Tests/RafuAppTests/CLIInstallerTests.swift`,
  `Tests/RafuCoreTests/LauncherArgumentParserTests.swift`
- **ADR**: [`0007-cli-app-location-symlink.md`](../decisions/0007-cli-app-location-symlink.md)
- **Related note**: [`launcher-cli.md`](launcher-cli.md) (argument grammar/validation)
- **Deferred**: a Launch-Services fallback (`open -a Rafu`) so the CLI survives
  the installed bundle being deleted — see ADR 0007's revisit trigger.
