# Language-server install staging & symlink validation

- Applies to: `nodeHosted`/`singleBinary` language-server installs, the managed Node runtime install, `StagingValidator` zip-slip defense
- Last verified: Swift 6.2, macOS 14+ (Darwin 25.1), 2026-07-16

## Rule or observed behavior

`StagingValidator.validate(staging:binaryRelativePath:)` runs after an asset is
unpacked into an isolated staging directory and before `AtomicDirectoryReplacer`
moves it into place. It rejects the whole install (`ServerInstallError.pathTraversal`)
if any entry's real path escapes staging.

Symlinks are **allowed when their target resolves back inside staging** and
rejected only when the target escapes. The target is resolved *lexically*:

- Read the link's declared destination with `destinationOfSymbolicLink(atPath:)`.
- Resolve it against the link's **real** parent directory
  (`link.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL`),
  then `standardizedFileURL` to collapse `..` without touching the filesystem.
- Require the result to equal `stagingRealPath` or have prefix `stagingRealPath + "/"`.

Lexical resolution (not `resolvingSymlinksInPath()` on the link itself) is
deliberate: a link to a not-yet-extracted or absent target must still be checked,
and `resolvingSymlinksInPath()` silently returns the *unresolved* link path when
the target does not exist — which would wrongly pass an escape whose target is
missing.

The declared binary itself must still not be a symlink.

## Why it matters

The prior policy rejected **every** symlink under staging as "strictly safe."
That broke every `nodeHosted` install. Node's official
`node-v<version>-darwin-arm64.tar.gz` ships three internal symlinks under `bin/`:

```
bin/corepack -> ../lib/node_modules/corepack/dist/corepack.js
bin/npx      -> ../lib/node_modules/npm/bin/npx-cli.js
bin/npm      -> ../lib/node_modules/npm/bin/npm-cli.js
```

All resolve within the tarball's own directory, but the blanket rejection threw
`pathTraversal` during `NodeRuntimeManager.ensureInstalled()`. That error was not
mapped in `LanguageServersCatalogModel.message(for:)`, so the user saw only the
generic **"The operation failed."** — masking a validator policy bug as an
unexplained install failure for Pyright and typescript-language-server.

`message(for:)` now maps `.pathTraversal`, `.unpackFailed`, and
`.unsupportedArchive` to specific text so a future genuine rejection is legible.

## Reproduction or evidence

- Node tarball symlinks confirmed by streaming the published tarball and listing
  its `bin/` symlink entries (the three links above).
- `StagingValidator` rejects the escaping case: `makeZipSlipTarGzip` builds a
  `.tar.gz` whose single entry is `escape -> /etc/passwd` (absolute, outside
  staging) → `pathTraversal`.
- `StagingValidator` accepts the internal case: `makeInternalSymlinkTarGzip`
  builds `package/bin/tool` (real, the declared binary) + `package/lib/impl.js`
  plus `package/bin/alias -> ../lib/impl.js` (relative, cross-directory, resolves
  inside staging) → install succeeds and the alias survives the atomic move.
- Fixture caveat: build the relative link with `createSymbolicLink(atPath:
  withDestinationPath:)`, **not** `withDestinationURL: URL(fileURLWithPath:)` —
  the URL initializer resolves a relative path against the CWD into an absolute,
  escaping target, which would make the "internal" fixture actually escape.

## Verification

- `swift test --filter ServerInstallerTests` — 11 tests, including:
  - "A zip-slip tar.gz fixture (a symlink escaping staging) is rejected and never installed"
  - "An internal (within-staging) symlink is accepted, mirroring Node's bin/npm links"
- `swift build`; full `swift test` (499 tests); `./script/format.sh --lint`
- `./script/build_and_run.sh --verify` (staged app relaunched for a live Pyright
  install retry)

## Related code, ADRs, and phases

- **Code**: `Sources/RafuApp/LanguageIntelligence/Registry/ServerInstaller.swift`
  (`StagingValidator.validate` + `requireSymlinkStaysInside`),
  `Sources/RafuApp/LanguageIntelligence/Registry/NodeRuntimeManager.swift`
  (`ensureInstalled` → unpack → validate),
  `Sources/RafuApp/LanguageIntelligence/Catalog/LanguageServersCatalogModel.swift`
  (`message(for:)`)
- **Tests**: `Tests/RafuAppTests/ServerInstallerTests.swift`,
  `Tests/RafuAppTests/FixtureAssetDownloader.swift`
- **Phase**: Lane 2, Stage C3 — see
  [`docs/plans/phases/lane-2-lsp-plan.md`](../plans/phases/lane-2-lsp-plan.md)
  (Zip-slip bullet updated to reflect the refined policy)
- **Related note**: [`workspace-trust-and-lsp-settings.md`](workspace-trust-and-lsp-settings.md)
- **Deferred residual (unchanged)**: a during-extraction symlink escape is still
  only catchable post-hoc; the lane-2 plan's pre-extraction entry-scan hardening
  follow-up remains open.
