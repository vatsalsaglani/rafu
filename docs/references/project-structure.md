# Project structure

- **Applies to:** targets, resources, shared contracts, and worktree setup
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-12

## Current target graph

```text
RafuCore (library; Foundation-only domain and launcher contracts)
├── RafuApp (SwiftUI GUI executable artifact)
└── RafuCLI (executable product `rafu`)

RafuCoreTests
```

The GUI artifact is intentionally `RafuApp`, not `Rafu`, because `Rafu` and `rafu` can collide on a case-insensitive filesystem. The staged app executable is renamed to `Rafu` inside `dist/Rafu.app`.

## Boundary rule

Feature folders describe responsibilities, but a new Swift target is justified only when it creates a useful dependency boundary, permits independent testing, or materially improves build behavior. Do not mirror the entire long-term source-layout sketch with empty modules.

`RafuCore` must remain usable by both the app and CLI and therefore must not import SwiftUI or AppKit. UI state and native view bridges belong to `RafuApp`. Launcher parsing/contracts may be shared; app activation and IPC endpoints remain product-specific.

## Resource rule

Canonical runtime resources live under `Resources/` and are staged into the app by `script/build_and_run.sh`. The raw theme files in `docs/plans/` are historical plan artifacts and still contain Darn/Linen naming. Do not ship them directly. Runtime copies use Rafu/Indigo/Khadi naming and IDs.

## Worktree prerequisite

The repository was initialized without a first commit. Git worktrees cannot fan out safely until the user creates or authorizes a bootstrap commit. After that, land shared contract changes before assigning workstreams that depend on them, and avoid parallel edits to `Package.swift`, `AGENTS.md`, or shared documentation indexes.

## Verification

```bash
swift package describe
swift build
swift test
```

## Related material

- [ADR 0001](../decisions/0001-swiftpm-bootstrap.md)
- Product plan §17
- Phase-plan index in `docs/plans/phases/`

