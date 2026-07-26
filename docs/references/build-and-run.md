# Build and run contract

- **Applies to:** local app/CLI builds, launch verification, and Codex Run
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-12

## One GUI entrypoint

Use `./script/build_and_run.sh` as the single kill, build, stage, and launch path for the GUI. A SwiftUI SwiftPM executable launched raw is not equivalent to a foreground macOS app: it lacks the bundle metadata and launch behavior used by normal application execution.

The script must:

1. Stop a previously running `Rafu` process.
2. Build the `RafuApp` and `rafu` products.
3. Stage `dist/Rafu.app` with `Contents/MacOS`, `Contents/Resources`, and `Contents/SharedSupport/bin`.
4. Copy and rename the GUI executable to `Contents/MacOS/Rafu`.
5. Copy the CLI to `Contents/SharedSupport/bin/rafu`.
6. Render the vector seam mark into a complete `.icns` iconset and copy it to
   `Contents/Resources/Rafu.icns`.
7. Generate local `Info.plist` metadata, including `CFBundleIconFile=Rafu.icns`
   and a `UTExportedTypeDeclarations` entry for the private editor drag UTI
   (`dev.vatsalsaglani.rafu.editor-drag`, conforming to `public.data`). The
   script asserts the staged identifier matches the Swift-side
   `UTType.rafuEditorDrag` literal after every stage — see
   [`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md) for why
   a missing or mismatched declaration silently breaks tab/file drag-and-drop.
8. Launch with `/usr/bin/open -n`.

## Supported modes

```bash
./script/build_and_run.sh             # build and launch
./script/build_and_run.sh --stage     # validate an ephemeral bundle without stopping or launching Rafu
./script/build_and_run.sh --verify    # launch and confirm the Rafu process exists
./script/build_and_run.sh --debug     # build and launch executable under lldb
./script/build_and_run.sh --logs      # launch, then stream process logs
./script/build_and_run.sh --telemetry # launch, then stream Rafu-subsystem logs
```

`--verify` may use a short bounded polling loop because it verifies an external process launch. Tests must not copy this approach as async synchronization.

## Other canonical commands

```bash
script/build.sh          # swift build, behind the lock guard
script/test.sh           # swift test, behind the lock guard
swift run rafu --help
```

The Codex environment action must invoke the same script and must not duplicate the staging logic.

## The `.build/.lock` hang (verified 2026-07-26)

SwiftPM takes an exclusive `flock` on `.build/.lock` for the whole build. A
second `swift build`/`swift test` on the same checkout does not fail fast —
it blocks with **no output whatsoever**, which is indistinguishable from a
slow compile. With several agent sessions or a Codex worktree sharing one
checkout this is the single most common "the build is hung" report, and it
has cost multi-minute waits before anyone checks. A build killed mid-flight
(or a crashed session) additionally leaves the file behind with no live
holder, after which every later invocation blocks on nothing, forever.

`script/await_build_lock.sh` encodes the diagnosis, and `script/build.sh` /
`script/test.sh` call it first:

- **Held vs. present are different states.** The file existing proves
  nothing. `lsof -t .build/.lock` lists processes holding it right now; that
  is the authoritative signal.
- **The file's contents are the owning pid**, written by SwiftPM. Verified on
  this checkout: `.build/.lock` contained `82636` for a long-dead process.
- **Remove only when BOTH say nobody**: no `lsof` holder AND `kill -0
  <recorded pid>` fails. `lsof` alone can miss a process mid-startup; a
  recycled pid can make a dead owner look alive. Deleting a lock that a live
  build holds corrupts nothing on its own but lets two builds write `.build`
  concurrently, which does.
- **Wait, don't kill.** Default `RAFU_LOCK_ATTEMPTS=4` × `RAFU_LOCK_WAIT=180`
  — roughly nine minutes of patience for a genuinely long build — then exit 1
  and report rather than forcing it.

Evidence: with a Python process holding an `flock`, the script reported the
holder pid and exited 1 across both attempts with the lock file intact; with
a stale file (no holder, dead pid) it removed the file and exited 0.

## Reclaiming worktree build caches (verified 2026-07-26)

Each `.build` is 2-5 GB. Phase fan-outs accumulate them: this repository
reached **20 build directories totalling 48 GB with 13 GB free**. SwiftPM
does not fail cleanly on ENOSPC — the symptom is a corrupt module cache and
"cannot find type in scope" errors that look like source bugs, so the agent
that hits it debugs the wrong thing.

Phase agents delete their own `.build` as their last step (see AGENTS.md,
"Worktree build cache"). The coordinator sweeps already-merged worktrees
from the primary checkout:

```bash
git worktree list --porcelain \
| awk '/^worktree /{w=$2} /^branch /{b=$2; sub("refs/heads/","",b); print w"\t"b}' \
| while IFS=$'\t' read -r w b; do
    [ "$b" = "main" ] && continue                                  # never the primary checkout
    [ -d "$w/.build" ] || continue
    git merge-base --is-ancestor "$b" main 2>/dev/null || continue # merged branches only
    pgrep -f "$w" >/dev/null 2>&1 && continue                      # skip anything live
    rm -rf "$w/.build"
  done
```

All three guards are load-bearing. Skipping `main` protects the checkout the
coordinator builds and launches from; the merge-base test keeps unmerged work
rebuildable; the `pgrep` test is what stops this from destroying an in-flight
agent's build. Swap `rm -rf` for `echo` to dry-run — do that first when any
agent is running.

Evidence: the sweep above reclaimed **29.5 GB** in one pass (13 GiB free ->
43 GiB), keeping `main`, two actively-running phase worktrees, and one
unmerged branch.

## CI and resource validation

The bootstrap GitHub workflow uses the explicit `macos-26` hosted-runner label and pins the official `actions/checkout` v6 tag commit verified on 2026-07-12. CI runs `script/verify.sh`; foreground GUI launch verification remains local.

Validate theme resources with `jq empty Resources/Themes/*.json`, the SVG with
`xmllint --noout Resources/AppIcon/rafu-icon-seam.svg`, and icon generation with
`script/generate_app_icon.sh`. A copied SVG is not a macOS bundle icon: the staged
bundle needs a complete `.icns` file at its Resources root and a matching
`CFBundleIconFile` entry. On the verified macOS 26.1 host, `plutil -lint` rejected
otherwise valid plain JSON at the opening `{`, so it is not the canonical
theme-JSON check.

## Troubleshooting order

1. Classify the failure as compiler, linker, package graph, staging script, bundle metadata, or runtime launch.
2. Run the narrowest direct build that exposes it: `swift build --product RafuApp` or `swift build --product rafu`.
3. Inspect `dist/Rafu.app/Contents/Info.plist`, `Contents/Resources/Rafu.icns`, and
   executable permissions for staging failures. Rebuild and relaunch the bundle
   before treating a previously cached Dock icon as current evidence.
4. Use `--logs` or `--telemetry` for startup/runtime behavior and `--debug` for a symbolized crash.
5. Do not add an ad hoc second run script.

## Related material

- [ADR 0001](../decisions/0001-swiftpm-bootstrap.md)
- `script/build_and_run.sh`
- `.codex/environments/environment.toml`
- [GitHub Actions runner images](https://github.com/actions/runner-images)
- [GitHub checkout action](https://github.com/actions/checkout)

The staged `dist/Rafu.app` is a local development artifact. SwiftPM's executable signature is not a sealed, Developer ID-signed application bundle, so it must never be uploaded as a release. Phase 5 owns nested-code signing, resource sealing, hardened runtime, notarization, and Gatekeeper validation.

## Packaging and releases

- `./script/build_and_run.sh --package` stages `dist/Rafu.app` without
  launching or deleting it — the mode CI uses to produce release artifacts.
- `RAFU_VERSION=<semver>` overrides the Info.plist bundle version at staging
  time; the release workflow also stamps the same version into
  `Sources/RafuCore/BuildInformation.swift` before building.
- `.github/workflows/release.yml`: pushing a `release/v<semver>` branch
  builds, verifies, zips, and publishes a GitHub release named for that
  version (the `v<semver>` tag is created automatically by the release — no
  manual tag management). A hyphenated version (e.g. `v0.1.0-beta`) publishes
  as a pre-release. The workflow refuses to run unless the latest completed
  CI run on `main` succeeded. Release notes include the
  `xattr -dr com.apple.quarantine` step required for the unsigned build.
- The generated Info.plist declares `CFBundleDocumentTypes` for
  `public.folder` so `open -a Rafu <folder>` (the CLI's mechanism) routes as
  a document-open event.
