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

## npm dependency resolution within staging (added 2026-07-17)

When a server descriptor declares `ArchiveLayout.npmPackageRoot` (e.g. `"package"` for typescript-language-server), the server's release tarball contains only source code; its dependencies are installed via `npm install` **while still in staging**, before the atomic move to the final install location.

**npm-cli derivation:** The npm entry point is derived from the managed Node runtime's layout. Node's official distribution ships `npm` as a symlink: `bin/npm -> ../lib/node_modules/npm/bin/npm-cli.js`. This path is computed from `nodeExecutableURL` (`bin/node`) by two `deletingLastPathComponent()` calls to reach the runtime root, then appending `lib/node_modules/npm/bin/npm-cli.js`.

**npm flags and rationale:** `node <npm-cli.js> install --omit=dev --no-audit --no-fund --ignore-scripts --no-package-lock --prefer-offline`

- `--omit=dev`: install production dependencies only.
- `--no-audit`: skip npm's advisory audit step (redundant with explicit consent).
- `--no-fund`: suppress funding notices.
- `--ignore-scripts`: **mandatory** — blocks arbitrary preinstall/postinstall lifecycle scripts. npm packages ship these hooks; without this flag, untrusted code runs with Rafu's privilege during every install. This is not optional hardening; it is the only defensible posture.
- `--no-package-lock`: do not write `package-lock.json` (Rafu does not own or version it).
- `--prefer-offline`: use npm's local cache when available, reducing network round-trips.

All output (stdout/stderr) is discarded to /dev/null; package names and registry URLs never appear in logs.

**Staging seam & rollback:** The npm step runs strictly AFTER `StagingValidator.validate` (line 427 in ServerInstaller) and BEFORE `AtomicDirectoryReplacer.replace` (line 439), so `node_modules/` is part of the atomic install move. If npm exits non-zero or `resolver.installDependencies()` throws, the function's `defer { try? fileManager.removeItem(at: isolationRoot) }` (line 421) discards staging entirely and the prior install remains untouched.

**ArchiveLayout.npmPackageRoot optional-field nuance:** The field is declared as `var npmPackageRoot: String?` with **no initializer** (`= nil` not written) and **no explicit `init`**. This preserves the compiler-synthesized memberwise initializer with a defaulted `nil` parameter, which is critical for two reasons:
1. Existing `language-servers.json` payloads (from an older version lacking this field) decode successfully because `Codable` synthesis omits missing optional keys.
2. When encoding, if `npmPackageRoot` is `nil`, the key is omitted entirely from the JSON (not included as `"npmPackageRoot": null`).

If the field were declared as `let npmPackageRoot: String? = nil`, the explicit initializer would **silently drop the parameter from the memberwise init** (Swift's compiler optimization), breaking existing call sites. If declared without `= nil`, the parameter remains required in the generated init, which would break existing code. The `var` without initializer is the unique pattern that keeps the init synthesized with an optional defaulted parameter.

## Related code, ADRs, and phases

- **Code**: `Sources/RafuApp/LanguageIntelligence/Registry/ServerInstaller.swift`
  (`StagingValidator.validate` + `requireSymlinkStaysInside`, `install` method lines 430–436),
  `Sources/RafuApp/LanguageIntelligence/Registry/NodeDependencyResolver.swift`
  (`NodeDependencyResolving` protocol + `NpmDependencyResolver`),
  `Sources/RafuApp/LanguageIntelligence/Registry/NodeRuntimeManager.swift`
  (`ensureInstalled` → unpack → validate),
  `Sources/RafuApp/LanguageIntelligence/Catalog/LanguageServersCatalogModel.swift`
  (`message(for:)`, `performInstall`, `performInstallPack`),
  `Sources/RafuApp/LanguageIntelligence/UI/ServerInstallConsentView.swift`
  (npm install disclosure)
- **Tests**: `Tests/RafuAppTests/ServerInstallerTests.swift` (npm integration, staging rollback),
  `Tests/RafuAppTests/FixtureAssetDownloader.swift` (fake `NodeDependencyResolving`)
- **Phases**: Lane 2, Stage C3 (symlink validation) — see
  [`lane-2-lsp-plan.md`](../plans/phases/lane-2-lsp-plan.md);
  lsp-production-readiness lane, P2 (npm dependency resolution) — see
  [`lsp-production-readiness.md`](../plans/phases/lsp-production-readiness.md)
- **ADRs**: [`0010-npm-supply-chain-and-checksum-policy.md`](../decisions/0010-npm-supply-chain-and-checksum-policy.md) (npm acceptance + transitive fetch mitigations), [`0005-language-intelligence-and-lsp.md`](../decisions/0005-language-intelligence-and-lsp.md)
- **Related note**: [`workspace-trust-and-lsp-settings.md`](workspace-trust-and-lsp-settings.md)
- **Deferred residual (unchanged)**: a during-extraction symlink escape is still
  only catchable post-hoc; the lane-2 plan's pre-extraction entry-scan hardening
  follow-up remains open. npm-installed native addons could be unsigned (AMFI SIGKILL on arm64) — typescript-language-server's deps are pure JS; residual recorded in ADR 0010.
