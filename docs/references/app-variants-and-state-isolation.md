# App variants and state isolation

- **Applies to:** local app staging, release packaging, app/CLI identity,
  Application Support, Keychain, launcher IPC, and CLI installation
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-26

## Rule

Local builds are **Rafu Lightning**. Release builds are **Rafu**. The two
variants share product code but never share process, bundle, Application
Support, Keychain, socket, or installed-CLI identity.

`RafuAppIdentity` is the sole constructor for Rafu-owned paths below
Application Support. New stores must call
`identity.applicationSupportRoot(...)`; they must not append a literal `Rafu`
component themselves. `AppSupportRootTests` scans the source tree to enforce
that rule.

## Identity resolution

Identity resolves in this order:

1. A recognized `Bundle.main` Info.plist (`dev.vatsalsaglani.rafu` or
   `dev.vatsalsaglani.rafu.lightning`).
2. The recognized app bundle enclosing the CLI. `LauncherAppLocator` follows
   the real executable path, including a `~/.local/bin` symlink, back to the
   staged app.
3. The release identity when neither bundle is recognized.

The final fallback is deliberately release, never Lightning. Tests and
`swift run` have no staged bundle; an unknown process must not silently claim
the development identity or its state.

`RafuBuildInformation` delegates app, CLI, and bundle naming to the resolved
identity. The app's window title, command menu, Settings header, and notch HUD
therefore match the enclosing bundle.

## Complete state map

| State | Release Rafu | Rafu Lightning |
|---|---|---|
| Process | `Rafu` | `RafuLightning` |
| Bundle | `dist/Rafu.app` | `dist/Rafu Lightning.app` |
| Bundle identifier | `dev.vatsalsaglani.rafu` | `dev.vatsalsaglani.rafu.lightning` |
| Application Support root | `~/Library/Application Support/Rafu/` | `~/Library/Application Support/Rafu Lightning/` |
| Launcher socket | `Rafu/ipc/v1.sock` | `Rafu Lightning/ipc/v1.sock` |
| Workspace trust | `Rafu/language-server-trust.json` | `Rafu Lightning/language-server-trust.json` |
| Server registry | `Rafu/language-servers.json` | `Rafu Lightning/language-servers.json` |
| Installed servers | `Rafu/LanguageServers/` | `Rafu Lightning/LanguageServers/` |
| Managed runtimes | `Rafu/Runtimes/` | `Rafu Lightning/Runtimes/` |
| User Ensemble library | `Rafu/conductor/` | `Rafu Lightning/conductor/` |
| User themes | `Rafu/Themes/` | `Rafu Lightning/Themes/` |
| Keychain service | `dev.vatsalsaglani.rafu.ai-provider-key` | `dev.vatsalsaglani.rafu.lightning.ai-provider-key` |
| Installed CLI link | `~/.local/bin/rafu` | `~/.local/bin/rafu-lightning` |
| Icon/HUD seam | gold `#E3A857` | silver `#C0C6CE` |

The phase inventory originally named five state construction sites. The source
guard exposed a sixth pre-existing site, `ThemeFileService`; it is isolated too
because imported or generated user themes are variant-owned state.

## Socket and CLI pairing

Both app bundles contain the same `Contents/SharedSupport/bin/rafu` product.
The release app installs the `rafu` symlink; Lightning installs
`rafu-lightning`. Following either link reveals its enclosing bundle identity,
which selects the matching Application Support root and socket. No flag or
discovery file is involved, and both links can coexist.

## Intentionally shared repository state

The repository-local `.rafu/` directory is shared by design. Ensemble
definitions, runs, and handoffs started from Lightning remain visible in
release Rafu because both variants are looking at the same repository files.
Do not move or copy `.rafu/` into a variant's Application Support root.

## Lightning starts empty

Real isolation means Lightning does not migrate or seed release state.
Workspaces must be trusted again, managed language servers download again,
user themes must be imported again, and AI provider keys must be entered
again in Lightning Settings. This one-time cost is intentional. Do not add a
migration, copy, or “seed from release” path.

## Build and packaging commands

Normal local work:

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

Release CI sets `RAFU_APP_NAME=Rafu` for packaging:

```bash
RAFU_APP_NAME=Rafu ./script/build_and_run.sh --package
```

Package mode stops and launches nothing, so the explicit release-artifact
check is safe. A human can explicitly launch a local release build with
`RAFU_APP_NAME=Rafu ./script/build_and_run.sh`, but normal development must
not do this: launch mode targets the selected process, which would collide
with an open release editor. Agents launch only Lightning.

## Why it matters

Process separation prevents a local relaunch from terminating the user's
editor. State, Keychain, and socket separation prevent subtler cross-variant
corruption and credential reads that would otherwise surface days after the
build that caused them. The silver seam is a visual confirmation, not the
safety boundary.

## Verification

```bash
./script/format.sh --lint
xmllint --noout Resources/AppIcon/rafu-icon-seam.svg
./script/build.sh
./script/test.sh
./script/test.sh --no-parallel
RAFU_APP_NAME=Rafu ./script/build_and_run.sh --package
./script/build_and_run.sh --verify
```

Inspect the staged Info.plists for `CFBundleExecutable`,
`CFBundleIdentifier`, and `CFBundleDisplayName`. Compare the exact release
process PID before and after Lightning verification without stopping or
signalling it.

## Related code, ADRs, and phases

- `Sources/RafuCore/RafuAppIdentity.swift`
- `Sources/RafuCore/Launcher/LauncherAppLocator.swift`
- `Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift`
- `script/build_and_run.sh`
- `docs/plans/phases/lightning-dev-build.md`
- ADR 0009 (launcher IPC)
