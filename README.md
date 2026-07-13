# Rafu

Rafu (રફૂ) is a focused, native macOS repository editor for the small edits that remain after a terminal coding agent has done the larger weave.

The project is intentionally narrow: independent workspace windows, native editing, broad lightweight syntax color, local and later SSH repositories, Git review, and explicit AI-assisted commit text. It does not aim to become an IDE, extension platform, terminal, debugger, or embedded coding agent.

## Project status

This repository is at the **pre-initial-push workbench checkpoint**. The native app provides restorable local workspaces, TextKit-backed editor groups, file and workspace find/replace, Git changes/history/branches and side-by-side diffs, GitHub-Flavored Markdown with native Mermaid diagrams, importable JSON themes, and explicit provider-backed commit drafting. The CLI remains a deliberately small launcher shell; SSH, app IPC, signing, notarization, and distribution stay in later phase plans.

The repository intentionally remains uncommitted until the hands-on acceptance pass succeeds. Its first commit must be staged and created from Rafu itself.

The active acceptance contract is [`docs/plans/phases/pre-initial-push-workbench.md`](docs/plans/phases/pre-initial-push-workbench.md). The canonical product and engineering plan is [`docs/plans/rafu_product_architecture_plan.md`](docs/plans/rafu_product_architecture_plan.md); later worktree-ready plans live beside the active brief.

## Requirements

- macOS 15 or newer for the bootstrap build
- Xcode 26.3 or a compatible Swift 6.2 toolchain

The public deployment target and production signing identity remain decisions to confirm before distribution.

## Quick start

```bash
swift build
swift test
swift run rafu --help
./script/build_and_run.sh --verify
```

The GUI run script builds both products, stages `dist/Rafu.app`, bundles the launcher under `Contents/SharedSupport/bin/rafu`, and opens the app as a normal foreground macOS application.

### Temporary local Gatekeeper workaround

Rafu is not signed or notarized yet. If macOS quarantines a downloaded local build,
first verify that you trust its source, then remove the quarantine attribute from
that app bundle:

```bash
xattr -dr com.apple.quarantine /path/to/Rafu.app
```

For the app staged by this repository, the path is `dist/Rafu.app`. This is only a
temporary local-testing workaround; do not disable Gatekeeper globally. Published
builds should use Developer ID signing and notarization instead.

## Repository map

```text
Sources/RafuCore/       shared value models and launcher contracts
Sources/RafuApp/        SwiftUI app, TextKit editor, Markdown preview, and Git client
Sources/RafuCLI/        small `rafu` command-line launcher shell
Tests/                  Swift Testing suites
Resources/              app-bundle resources staged by the run script
script/                 canonical local build/run commands
docs/decisions/         accepted ADRs and unresolved decisions
docs/references/        verified engineering guidance and nuances
docs/plans/phases/      phase/worktree execution plans
.agents/skills/         project-local specialist skills
```

Read [`AGENTS.md`](AGENTS.md) before implementation work. It contains the architecture invariants, phase contract, verification requirements, and standing documentation rule.

## GitHub and distribution

The repository is intended for GitHub, but no license or release channel is assumed by this checkpoint. Direct Developer ID signing and notarized distribution are planned for Phase 5. Release automation, signing secrets, update delivery, and the project license require explicit decisions before they are added.
