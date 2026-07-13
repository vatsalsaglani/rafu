# ADR 0001: SwiftPM bootstrap workspace

- **Status:** Accepted for bootstrap
- **Date:** 2026-07-12
- **Scope:** Pre-Phase-0 repository foundation

## Context

The repository began with product plans and no app project. The first checkpoint needs a reproducible native macOS shell, a separate CLI, shared value models, tests, and a Codex Run action without prematurely choosing editor, syntax, Markdown, SSH, or packaging dependencies.

The plan suggests keeping feature folders together until boundaries stabilize. It also ultimately needs separate app and launcher products and a signed application bundle.

Normal macOS workspaces are commonly case-insensitive, so executable products named only `Rafu` and `rafu` would collide in SwiftPM build output.

## Decision

- Use a single Swift 6.2 package as the bootstrap source of truth.
- Create three targets:
  - `RafuCore`, a Foundation-only shared library.
  - `RafuApp`, the SwiftUI GUI executable product.
  - `RafuCLI`, exposed as the executable product `rafu`.
- Keep the GUI build artifact named `RafuApp` to avoid a case-only collision with `rafu`.
- Stage the GUI artifact as `dist/Rafu.app/Contents/MacOS/Rafu` in the canonical run script.
- Build and place the CLI at `Rafu.app/Contents/SharedSupport/bin/rafu` so the bundle reflects the intended shipping layout.
- Use no third-party dependencies during bootstrap.
- Target macOS 15 for the scaffold, matching the current plan recommendation. Treat the public minimum as unresolved until it is explicitly locked.
- Use `dev.vatsalsaglani.rafu` only as provisional local bundle metadata until the signing identity is confirmed.

## Alternatives considered

### Hand-authored Xcode project immediately

This provides production app-target controls now, but adds fragile project metadata before target and dependency boundaries are proven.

### Multiple Swift packages immediately

This enforces more boundaries, but conflicts with the plan's direction to extract packages only after they demonstrate independent value.

### Case-only executable names

Rejected because build artifacts can collide on the default case-insensitive macOS filesystem.

## Consequences

- `swift build` and `swift test` are enough for repeatable bootstrap verification.
- The GUI must be launched through `script/build_and_run.sh`, which stages a real `.app`; raw `swift run RafuApp` is not the normal GUI path.
- App resources are explicitly staged into the bundle by the run script until a production Xcode/archive path is adopted.
- SwiftPM is not yet the final signing, entitlement, archive, or notarization decision.
- Phase 0 may add target boundaries only when a feasibility workstream benefits from independent compilation or testing.

## Revisit triggers

Revisit when Phase 0 needs AppKit editor dependency integration that materially benefits from another module, or when Phase 5 establishes production signing, entitlements, archives, and notarization.

## Related material

- Product plan §§5, 9, 15, and 17
- [`../references/project-structure.md`](../references/project-structure.md)
- [`../references/build-and-run.md`](../references/build-and-run.md)
- `Package.swift`
- `script/build_and_run.sh`

