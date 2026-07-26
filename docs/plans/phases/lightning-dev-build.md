# LT-01 — Rafu Lightning: a dev build that cannot kill your editor

- **Status:** Complete. Branch: `dev/lightning-variant` (from `main`).
  Runs in parallel with C8-04 and C8-07 (wave 3). Not an Ensemble phase —
  it changes how every phase from here on is built, launched, and verified.
- **Why now:** dogfooding Rafu while agents build Rafu is unsafe today.
  `script/build_and_run.sh:53` runs `pkill -x Rafu` on every launch, and
  agents type it by hand too. Both kill the editor the user is working in,
  with no warning and no recovery. Every merge from here ends with a build
  and launch, so the collision is routine, not hypothetical.

## Goal

Ship **Rafu Lightning**: a locally-built variant that is the same product
with a different identity — different process name, different bundle id,
different on-disk state, and a visibly different (silver, not golden) seam
in its icon and notch HUD. Local builds produce Lightning **by default**,
so the sanctioned scripts are structurally incapable of touching a release
Rafu. GitHub Actions overrides one variable to produce the real thing.

The visual difference is for the human. **The safety comes from the
process name and the state separation** — treat those as the deliverable
and the icon as the finish.

## Read first

`AGENTS.md` (canonical commands, build-lock section); `docs/references/build-and-run.md`;
`script/build_and_run.sh` (the `APP_NAME` variable at line 5 drives bundle
name, executable, `CFBundleIdentifier`, `CFBundleName`, `pgrep`, and the
`pkill` at line 53); `script/generate_app_icon.sh`; `.github/workflows/release.yml`
(calls `build_and_run.sh --package` and asserts `dist/Rafu.app`);
`Sources/RafuCore/BuildInformation.swift`;
`Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift`
(`LauncherIPCSocketPath`); `Sources/RafuCore/Launcher/LauncherAppLocator.swift`
(the CLI already resolves its enclosing bundle — this plan depends on it);
`Sources/RafuApp/Services/CLIInstaller.swift`.

## Owned paths

- `script/build_and_run.sh`, `script/generate_app_icon.sh`, `script/verify.sh`
- `.github/workflows/release.yml` (one env var), `.github/workflows/ci.yml`
  only if CI asserts a bundle path
- `Resources/AppIcon/` — the seam SVG plus a variant
- NEW `Sources/RafuCore/RafuAppIdentity.swift`
- `Sources/RafuCore/BuildInformation.swift`
- `Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift` — **only**
  `LauncherIPCSocketPath` (~line 164-180). C8-04 adds a request kind near
  line 36 in parallel; stay out of that region.
- `Sources/RafuApp/LanguageIntelligence/Registry/{WorkspaceTrustStore,ServerRegistry,ServerInstaller}.swift`
  — the Application Support root only
- `Sources/RafuApp/Conductor/Library/ConductorDefinitionLibrary.swift`
  — `defaultUserLibraryRoot` only
- `Sources/RafuApp/AI/AISecretStore.swift` — the Keychain service string
- `Sources/RafuApp/Services/CLIInstaller.swift` — variant-aware symlink name
- Notch HUD tint: `Sources/RafuApp/Terminal/NotchHUD*.swift` (locate the
  accent site; keep the change to a token)
- `Sources/RafuApp/App/RafuApp.swift`, `RafuAppCommands.swift`,
  `Settings/RafuSettingsView.swift` — display name only where it is
  currently the literal `"Rafu"`
- NEW tests `Tests/RafuCoreTests/RafuAppIdentityTests.swift`,
  `Tests/RafuAppTests/AppSupportRootTests.swift`
- `AGENTS.md` (canonical commands + a new rule — see below),
  `docs/plans/phases/conductor/README.md` (ground rules bullet),
  NEW `docs/references/app-variants-and-state-isolation.md`, this plan's
  status line.

**Forbidden:** everything C8-04 owns (Ensemble engine, request service,
`ConductorRunDetailCanvas`, `ConductorGraphModel`, `Sources/RafuCore/Ensemble/`,
`LauncherIPCServer.swift`, the request-kind region of `LauncherIPCProtocol.swift`)
and everything C8-07 owns (`EnsembleStartSheet`, `WorkspaceSession`,
`WorkspaceWindowView`, `CommandPaletteView`, `ConductorRunsPanelView`).
You may edit `RafuAppCommands.swift` **only** for the menu's display
string; C8-07 adds a ⌘⇧E item to the same file, so keep your hunk to that
one line and expect a trivial serial merge.

## Design contract

### 1. Identity, derived not hardcoded

NEW `Sources/RafuCore/RafuAppIdentity.swift`:

```swift
public struct RafuAppIdentity: Sendable {
    public let displayName: String            // "Rafu" | "Rafu Lightning"
    public let bundleIdentifier: String       // dev.vatsalsaglani.rafu[.lightning]
    public let applicationSupportDirectory: String  // "Rafu" | "Rafu Lightning"
    public let isLightning: Bool
}
```

Resolution order, and this ordering is the point:

1. **From a bundle Info.plist** when one is available — the app reads
   `Bundle.main`; the CLI reads the bundle it is installed inside, which
   `LauncherAppLocator.enclosingAppBundle()` already resolves from the real
   executable path. This is what makes `Rafu Lightning.app`'s staged CLI
   talk to Lightning and the release CLI talk to release, automatically.
2. **Fall back to the release identity** when there is no bundle (unit
   tests, `swift run`). Never fall back to Lightning: an unknown context
   must not silently write into the dev variant's state either.

`RafuBuildInformation` keeps `cliName`/`version` and delegates naming to
`RafuAppIdentity`.

### 2. The state roots — the load-bearing change

Five files independently construct `~/Library/Application Support/Rafu/…`
today, plus the socket. Route **every** one through the identity:

| Site | Today |
|---|---|
| `LauncherIPCSocketPath.resolve` | `Rafu/ipc/v1.sock` |
| `WorkspaceTrustStore` | `Rafu/` |
| `ServerRegistry` | `Rafu/` |
| `ServerInstaller` | `Rafu/` |
| `ConductorDefinitionLibrary.defaultUserLibraryRoot` | `Rafu/conductor/` |

Add one accessor (`RafuAppIdentity.applicationSupportRoot`) and make all
five call it. **Missing one means Lightning silently writes into the
user's real Rafu state** — no error, no log line, discovered days later.
That is why this is a consolidation, not five suffixes.

Keychain: `AISecretStore`'s service becomes `<bundleIdentifier>.ai-provider-key`,
so Lightning cannot read release's provider keys.

**Guard test** (`AppSupportRootTests`): a source scan asserting no file
outside `RafuAppIdentity.swift` constructs an `applicationSupportDirectory`
path for Rafu's own state. This is the regression that would otherwise
recur every time someone adds a store.

### 3. The script inversion

`script/build_and_run.sh`:

```bash
APP_NAME="${RAFU_APP_NAME:-Rafu Lightning}"
APP_EXECUTABLE="${APP_NAME// /}"     # RafuLightning — no space, so pgrep/pkill stay simple
```

`CFBundleExecutable` and the binary use `APP_EXECUTABLE`; `CFBundleName`
and the display use `APP_NAME`; `CFBundleIdentifier` gains `.lightning`
when the variant is Lightning. `pkill`/`pgrep` target `APP_EXECUTABLE`,
so they can only ever match the variant being built.

`.github/workflows/release.yml`: set `RAFU_APP_NAME: Rafu` on the packaging
step. Its existing `dist/Rafu.app` assertion then still holds. Check
`ci.yml` and `verify.sh` for any bundle-path assumption and keep them
variant-agnostic.

### 4. CLI symlink

`CLIInstaller` installs `rafu` for release and **`rafu-lightning`** for
Lightning, so both can coexist in `~/.local/bin`. Each resolves its own
enclosing bundle and therefore its own socket — no ambiguity, no flag.
Report which name was installed.

### 5. The visible difference

The icon SVG has exactly three colours; the zari is `#E3A857`. Parameterize
`generate_app_icon.sh` to take a seam colour (or add a variant SVG) and give
Lightning a **silver** seam — start from `#C0C6CE` and adjust by eye; it must
stay legible at 16pt in the Dock and in ⌘-Tab.

Also make Lightning legible where names are read, not icons: the window
title, the `CommandMenu`, and the Settings header show "Rafu Lightning".
Give the notch HUD the same silver treatment via its accent token — locate
the tint site rather than hardcoding a colour at the call site.

## What this deliberately does NOT isolate

`.rafu/` — agents, workflows, and runs — lives **in the repository**, not
in Application Support. Runs an agent starts in Lightning therefore appear
in the user's release Rafu too, because they are the same files on disk.
That is intended: the user watches agent activity from their own editor.
Say so explicitly in the reference note so nobody later "fixes" it.

## Consequence to state plainly

Lightning starts with **empty** state: workspaces need re-trusting,
language servers re-download, AI provider keys must be re-entered in
Lightning's Settings. That is the cost of real isolation and it is a
one-time cost — do not add a migration or a "seed from release" path.
Document it in the reference note under a heading the user will find.

## Tests

- `RafuAppIdentityTests`: release identity from a release Info.plist
  fixture; Lightning identity from a Lightning fixture; **no-bundle falls
  back to release, never Lightning**; application-support directory name
  and Keychain service derive from the bundle id.
- `AppSupportRootTests`: the source-scan guard above; plus each of the five
  sites resolves under the identity root for both variants.
- Socket path differs between variants (so the two apps cannot fight).
- `CLIInstaller` picks `rafu` vs `rafu-lightning` by variant.

## Gates

`./script/build.sh` 0 warnings; `./script/test.sh` AND
`./script/test.sh --no-parallel` green; `./script/format.sh --fix` then
`--lint` clean; `xmllint --noout` on any new/edited SVG.

**You MAY run `./script/build_and_run.sh --verify` in this phase** — that
is the exception to the headless-only rule, because launching is the thing
under test. It now builds Lightning, so it cannot disturb a running Rafu.
Verify by name: after `--verify`, `pgrep -x RafuLightning` succeeds and
`pgrep -x Rafu` is unaffected. Do not kill any process named `Rafu`.

## Documentation deliverables

NEW `docs/references/app-variants-and-state-isolation.md`: the identity
resolution order and why no-bundle falls back to release; the full state
table; the socket/CLI pairing; the in-repo `.rafu/` exception; the
empty-state consequence; how to build a release locally
(`RAFU_APP_NAME=Rafu ./script/build_and_run.sh`) and why you normally
should not.

`AGENTS.md`: update the canonical commands to say local builds produce
Rafu Lightning, and add a standing rule — **agents build, launch, and kill
only Rafu Lightning; never `pkill`/`pgrep` a bare `Rafu`; a release build
is a CI action, not a local one.** Add the same as a bullet in
`docs/plans/phases/conductor/README.md`'s worktree ground rules, since
every phase prompt inherits them.

## Handoff report

Delivered behavior; changed paths; test evidence; the exact
before/after of every state path; confirmation that `pgrep -x Rafu` is
unaffected by a Lightning launch; the silver seam rendered at 16/32/128pt
(describe it — the coordinator eyeballs it on `main`); remaining risks;
branch; every commit message; `git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: dev/lightning-variant. Preflight: run `git status --short --branch`
ONCE. On this branch + clean tree → proceed. Detached HEAD or wrong branch
+ clean tree → checkout the branch if it exists, else
`git checkout -b dev/lightning-variant main`, then proceed and say so.
Dirty tree with edits you did not make → STOP and report.

You run in parallel with C8-04 and C8-07. Their files are off-limits (the
plan lists them). You share exactly one file with C8-04:
Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift — you edit only
LauncherIPCSocketPath (~line 164-180); C8-04 edits the request-kind enum
(~line 36). Stay in your region.

GOAL: implement docs/plans/phases/lightning-dev-build.md — ship "Rafu
Lightning", a locally-built variant with its own process name, bundle id,
Application Support root, Keychain service, IPC socket, CLI symlink, and a
silver seam in its icon and notch HUD. Local builds produce Lightning by
DEFAULT so build_and_run.sh can no longer touch a release Rafu; GitHub
Actions sets RAFU_APP_NAME=Rafu for releases. The plan file is your
authoritative design contract, edit list, and test list — read it FIRST,
then AGENTS.md, docs/references/build-and-run.md, and the files the plan's
"Read first" section names.

WHY THIS EXISTS, so you weigh the parts correctly: today
script/build_and_run.sh runs `pkill -x Rafu` on every launch, which kills
the editor the user is working in. The safety comes from the process name
and the state separation. The icon is the finish, not the deliverable.

HARD CONSTRAINTS: all five Application Support sites plus the socket must
route through ONE identity helper — a missed site means Lightning silently
corrupts the user's real Rafu state, so the guard test that no other file
builds such a path is mandatory; identity resolves from the enclosing
bundle (the CLI already locates its own bundle via LauncherAppLocator) and
falls back to RELEASE when no bundle exists, never to Lightning; the
executable name has no space (RafuLightning) so pgrep/pkill stay simple;
never add a migration or "seed from release" path — empty Lightning state
is the intended cost; do not isolate the in-repo .rafu/ directory, which
is shared by design; user-visible strings say "Rafu Lightning". DO NOT
touch any file the plan lists as C8-04's or C8-07's.

You MAY run ./script/build_and_run.sh --verify here — launching is the
thing under test, and it now builds Lightning. But NEVER kill, pkill, or
pgrep a bare process named "Rafu": that is the user's editor. Verify with
`pgrep -x RafuLightning`, and confirm `pgrep -x Rafu` is unaffected.

DEFINITION OF DONE:
1. `./script/build_and_run.sh --verify` builds and launches Rafu
   Lightning; a Rafu already running is provably untouched.
2. `RAFU_APP_NAME=Rafu ./script/build_and_run.sh --package` still produces
   dist/Rafu.app with the release identity, and release.yml sets it.
3. Every state root (socket, trust store, server registry, server
   installer, conductor library, Keychain) differs between variants, with
   the guard test proving no site escapes the helper.
4. `rafu` and `rafu-lightning` coexist, each talking to its own app.
5. The silver seam renders legibly at 16/32/128pt; window title, menu, and
   Settings header read "Rafu Lightning".
6. build 0 warnings; test.sh AND test.sh --no-parallel green; format
   --fix + --lint clean; xmllint clean on any SVG.
7. AGENTS.md and the conductor README ground rules carry the new rule;
   app-variants-and-state-isolation.md written; intended index row in the
   report only (never edit shared indexes).
8. Work committed locally in verified stages; never push/merge/rebase/
   checkout main. A shared-file need is a HANDOFF with a proposed diff.

FINAL REPORT (mandatory): delivered behavior; changed paths; test
evidence; a before/after table of every state path; proof that a running
Rafu was unaffected; how the silver seam looks at small sizes; remaining
risks; branch name; every commit message; last commit id from
`git rev-parse HEAD`.
```
