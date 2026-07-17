# ADR 0010: npm supply chain and checksum policy

- **Status:** Proposed (2026-07-17; user acceptance converts to Accepted at merge)
- **Date:** 2026-07-17

## Context

Rafu commits to checksum-everything: every installed server binary is verified against a published digest (trust-on-first-download + cross-check where upstream publishes) or never installed. The managed Node runtime follows this model: its tarball is verified and atomic-moved as a unit.

Most bundled servers (rust-analyzer, clangd, pyright, sourcekit-lsp) are self-contained single-file or pre-bundled-dependency releases. typescript-language-server differs: its official npm tarball (published on registry.npmjs.org) contains only the TypeScript compiler wrapper itself; its dependencies (TypeScript, Node LSP client libraries, `node_modules/`) are installed separately via `npm install` at unpack time. This is a deliberate distribution choice by the TypeScript team and reflects how npm packages are authored and published — the exact bytes of `node_modules/` are transitive, version-pinned in `package-lock.json` (which npm owns), and re-downloadable but never pre-vendored in the release tarball.

Accepting a node-hosted server (one whose release requires `npm install` to become runnable) without vendoring a `package-lock.json` or offline cache means accepting an unpinned transitive fetch from registry.npmjs.org. This violates the checksum-everything posture — a re-publish of the same package version under a different dependency tree would pass silently.

Three options:

1. **Accept unpinned transitive npm fetch with mitigations, and disclose explicitly.** Apply `--ignore-scripts` (mandatory: blocks arbitrary preinstall/postinstall execution), `--omit=dev`, `--no-audit`, `--no-fund`, `--no-package-lock`, `--prefer-offline`. Never log package names, registry URLs, or npm argv. Run the step in staging so `node_modules/` rides the atomic install move (rollback on failure restores the prior state). Provide an explicit, honesty-first consent sheet naming npm install + registry.npmjs.org and stating packages are not individually pinned or checksum-verified.

2. **Vendor a per-entry `package-lock.json` + offline cache, and pin those.** Requires human network access per server version (fetch and commit the cache), human review of what npm resolves, and bloats the repository. Revisit if a nodeHosted server ships an unsigned native addon (AMFI SIGKILL residual on arm64) or reproducibility becomes a requirement — at that point the cache becomes the only defense.

3. **Do not support nodeHosted servers; accept only self-contained bundles.** Loses typescript-language-server (widely used, trivial to fetch); misses future ecosystem opportunities. Rejected.

**Decision: option 1 is chosen.** It is a principled exception rather than silent drift: npm's own design makes transitive pinning infeasible without vendoring, the mitigations reduce runtime risk materially, and the consent disclosure keeps the tradeoff visible to the user. Revisit when a server ships native addons or reproducibility demand changes.

## Decision

**Part A: Unpinned transitive npm fetch — accepted with mitigations.**

- **When:** A `ServerDescriptor.archive?.npmPackageRoot` is non-nil (e.g. typescript-language-server's `"package"`), the descriptor names an npm-distributed server whose tarball requires `npm install`.
- **How:** `ServerInstaller.install` spawns `node <runtimeRoot>/lib/node_modules/npm/bin/npm-cli.js install --omit=dev --no-audit --no-fund --ignore-scripts --no-package-lock --prefer-offline` with `currentDirectoryURL = <staging>/<npmPackageRoot>` (e.g. `<staging>/package`), sourced from the managed Node runtime (`nodeExecutableURL`). `--ignore-scripts` is UNCONDITIONAL and mandatory — npm packages' `preinstall`/`postinstall` lifecycle scripts run with Rafu's privilege during every install and would represent an arbitrary-code-execution surface without this flag.
- **Atomic safety:** The npm step runs strictly between `StagingValidator.validate` (after unpack, before npm) and `AtomicDirectoryReplacer.replace` (after npm, before move to install), so `node_modules/` is part of the atomic move. On any non-zero exit or exception, the `defer` discards staging and the prior install is untouched (rollback intact).
- **Logging:** Never log resolved package names, registry URLs, or npm arguments to any persistent medium — Rafu's security boundary excludes implicit network access from the user's control.
- **Disclosure:** `ServerInstallConsentView` shows explicit, static text (no URLs/paths/command names injected) stating this server's install also runs `npm install`, fetches additional unpinned packages from registry.npmjs.org, and these packages are not individually pinned or checksum-verified. `npm install` is named only when `npmPackageRoot` is non-nil.

**Part B: Checksum-source policy.**

Rafu pins a LOCALLY-COMPUTED SHA-256 of the exact downloaded bytes (trust-on-first-download), never constructed from an algorithm-tagged digest type. The locally-computed hash is cross-checked against upstream digests where published (npm packument's `dist.integrity` field as SHA-512 — converted and compared as a sanity check, not used as the canonical pin; GitHub release assets' upstream digests where available).

Do **not** build a speculative algorithm-tagged digest extension (e.g. `{ "algorithm": "sha256", "value": "…" }`) in anticipation of future checksum-source diversification. The current single-hash scheme is sufficient; a future need for multiple algorithms is a separate ADR.

## Consequences

- typescript-language-server becomes usable: installs and runs with explicit user consent for npm's transitive fetch.
- npm needs network at install time. Offline tests use the injected fake `NodeDependencyResolving`; a real install is never CI-verified (same posture as the download seam, already accepted in ADR 0005's implementation).
- `node_modules/` in temp staging enlarges the known cross-volume non-atomic `moveItem` residual: `AtomicDirectoryReplacer` already handles this via the aside-and-restore fallback, and the atomic move of npm's output restores the prior install on exception. The risk is acceptable.
- npm-installed native addons could be unsigned (AMFI SIGKILL on arm64 running a native module). typescript-language-server's deps are pure JavaScript — **residual:** record as a future review point if another nodeHosted server ships native code.
- Package.swift and Package.resolved remain unchanged: npm runs under the managed Node runtime and uses the system /usr/bin/tar, /usr/bin/gunzip, /usr/bin/ditto, and spawn API. No new package dependency.

## Alternatives considered

1. **Accept with mitigations + disclose (chosen).** Balances security, user control, and feasibility.
2. **Vendor a `package-lock.json` + offline cache per entry.** Eliminates the transitive-fetch vulnerability but requires human network access, adds repository bloat, and is only necessary if native addons or reproducibility demand arrives. Deferred — the trigger is explicit.
3. **Do not support nodeHosted servers.** Loses ecosystem opportunity and typescript-language-server for no strong reason.

## Revisit trigger

- **Native addon requirement:** if a future nodeHosted server ships an unsigned native addon and AMFI SIGKILL becomes unavoidable, consider option 2 (offline cache + vendored lock).
- **Reproducibility demand:** if the product requires bit-exact reproducibility across CI runs, vendoring becomes necessary. At that point, a dedicated P-lane step pins a per-entry `package-lock.json` and offline npm cache.

## Related

- **ADR 0005:** [`0005-language-intelligence-and-lsp.md`](0005-language-intelligence-and-lsp.md) — defines the transparent, user-controlled server registry and explicit installs; this ADR refines the install seam to permit npm-hosted servers under the same registry.
- **Code:** `Sources/RafuApp/LanguageIntelligence/Registry/NodeDependencyResolver.swift` (protocol + `NpmDependencyResolver`), `ServerInstaller.install` (npm step in staging), `ArchiveLayout.npmPackageRoot` (optional field + synthesized init), `CuratedCatalog.swift` (typescript-language-server descriptor), `ServerInstallConsentView` (disclosure text mapping).
- **Tests:** `Tests/RafuAppTests/ServerInstallerTests.swift` (npm integration + rollback), fake `NodeDependencyResolving` in test fixtures.
- **Phase:** lsp-production-readiness.md, P2 — npm dependency resolution (G1).
