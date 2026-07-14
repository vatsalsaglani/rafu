# Architecture decisions

This directory records durable Rafu decisions that have meaningful alternatives or long-term consequences.

## Decision order

Accepted ADRs take precedence over older plan suggestions when they explicitly supersede them. The canonical product plan still controls product intent and scope. A phase plan may defer a decision, but it must not quietly contradict an accepted ADR.

## Index

| ADR | Status | Decision |
|---|---|---|
| [0001](0001-swiftpm-bootstrap.md) | Accepted for bootstrap | Use one dependency-free SwiftPM workspace for the initial GUI, CLI, shared core, and tests |
| [0002](0002-native-workbench-navigation.md) | Partially superseded by 0003 | Use one native workbench Navigator and editor-hosted details |
| [0003](0003-files-left-utility-right.md) | Accepted | Files-only left sidebar; Search and Source Control in a right utility panel |
| [0004](0004-embedded-terminal.md) | Accepted | Adopt a lazy, bounded embedded terminal panel built on SwiftTerm |
| [0005](0005-language-intelligence-and-lsp.md) | Accepted | Tree-sitter as the real syntax engine plus an opt-in, memory-bounded LSP client with a transparent, user-controlled server registry |

Unresolved choices are tracked in [`open-decisions.md`](open-decisions.md).

## ADR template

Each ADR contains:

- Status and date
- Context
- Decision
- Alternatives considered
- Consequences
- Revisit trigger, if any
- Related plan, reference, and implementation paths

Do not rewrite the historical decision when circumstances change. Add a superseding ADR and update this index.
