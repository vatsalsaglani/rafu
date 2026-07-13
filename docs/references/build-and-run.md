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
swift build
swift test
swift run rafu --help
```

The Codex environment action must invoke the same script and must not duplicate the staging logic.

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
