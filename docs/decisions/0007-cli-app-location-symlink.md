# ADR 0007: The rafu CLI locates Rafu.app via an in-bundle symlink and its real executable path

- **Status:** Accepted
- **Date:** 2026-07-17

## Context

`rafu <path>` opens a folder by locating the enclosing `Rafu.app` and running
`open -a <bundle> <folder>` (`Sources/RafuCLI/main.swift`). Two independent
defects made this fail for the normal, installed invocation `rafu .`:

1. **The installer copied the CLI out of the bundle.** `CLIInstaller` copied
   `Rafu.app/Contents/SharedSupport/bin/rafu` to `~/.local/bin/rafu`. A plain
   copy has no `Rafu.app` above it, so `LauncherAppLocator` — which finds the
   bundle by walking four components up from the CLI's own path — could never
   locate the app from an installed CLI. It only worked when the binary was run
   from *inside* the bundle. The copy also went stale on every app rebuild
   until the user manually reinstalled, which is exactly how a user hit a
   months-old binary still printing a since-removed "app IPC is not implemented"
   message.
2. **The locator trusted `argv[0]`.** `LauncherAppLocator.enclosingAppBundle()`
   used `CommandLine.arguments.first` as its executable path. When the CLI is
   invoked bare through `PATH` (`rafu .`), the shell sets `argv[0]` to just the
   basename `"rafu"`, which `URL(fileURLWithPath:)` resolves against the current
   directory — never finding the executable. Invoking by absolute path happened
   to work only because `argv[0]` was then a real path.

Alternatives considered for how the CLI finds the app:

1. **Symlink install + real executable path** — install `~/.local/bin/rafu` as
   a symlink into the bundle, and resolve the CLI's real path from
   `_NSGetExecutablePath()`. The kernel exec's the fully-resolved path even when
   `argv[0]` is a basename, and `resolvingSymlinksInPath()` follows the symlink
   back into `Rafu.app`. Auto-tracks rebuilds; the only failure mode is a
   dangling link after the specific bundle is moved/deleted, which surfaces as a
   clear locator error. **Chosen.**
2. **Copy install + Launch Services lookup** — keep copying, but find the app by
   bundle identifier (`open -a Rafu`). Self-contained and survives bundle moves,
   but macOS chooses *which* registered `Rafu.app`, which is ambiguous during
   development (a `dist/` build vs. an `/Applications` copy) and could open a
   different app than the one the CLI was installed from. Rejected as the
   default; recorded as a possible future fallback.
3. **Both (symlink primary, Launch Services fallback)** — most robust, largest
   surface. Deferred: not worth the extra code and multi-copy ambiguity until a
   real need for "works after the bundle is deleted" appears.

## Decision

- `CLIInstaller` installs `~/.local/bin/rafu` as a **symlink** to the running
  bundle's `Contents/SharedSupport/bin/rafu`, not a copy. It replaces an
  existing symlink (detected without following it, so a dangling link is still
  cleaned up) or a regular file left by the old copy-based installer; it refuses
  to clobber a directory or anything else.
- `LauncherAppLocator.enclosingAppBundle()` resolves the running executable's
  real path from `_NSGetExecutablePath()` (falling back to `argv[0]` only if the
  probe fails), then `resolvingSymlinksInPath()` before the four-component
  walk-up. `executablePath` is an injectable override used only by tests.
- The bundle location remains the walk-up: the CLI is at
  `Rafu.app/Contents/SharedSupport/bin/rafu`, so the bundle is four components
  up, still gated on a real `Contents/MacOS` on disk.

## Consequences

- `rafu .` invoked bare through `PATH` now locates the app and opens the folder;
  the CLI auto-tracks app rebuilds (the symlink target is rebuilt in place), so
  it no longer silently goes stale.
- The CLI is bound to the specific bundle it was installed from. If that bundle
  is moved or deleted, the symlink dangles and the locator reports
  "could not locate Rafu.app" — the user reinstalls from the command palette.
  (This is the accepted trade of alternative 1 over a Launch Services lookup.)
- `CLIInstallerError` is now `Equatable` (for test assertions). `CLIInstaller`
  gained injectable `source`/`binDirectory` so its symlink logic is unit-tested
  against temporary directories instead of the real home directory.
- During development the installed symlink points into the repo's `dist/Rafu.app`
  staging path; that path is stable across `build_and_run.sh` runs, so a dev's
  `rafu` tracks each rebuild without reinstalling.

**Revisit trigger:** if "the CLI must keep working after its bundle is deleted"
becomes a real requirement (e.g. a signed `/Applications` install that users
relocate), add the alternative-2 Launch Services fallback behind the existing
locator, making this alternative 3.

**Related:** `docs/references/launcher-cli.md`,
`docs/references/cli-app-location.md`;
`Sources/RafuCore/Launcher/LauncherAppLocator.swift`,
`Sources/RafuApp/Services/CLIInstaller.swift`, `Sources/RafuCLI/main.swift`;
`Tests/RafuAppTests/CLIInstallerTests.swift`,
`Tests/RafuCoreTests/LauncherArgumentParserTests.swift`.
