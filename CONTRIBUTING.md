# Contributing to Rafu

Rafu is in an early, phase-gated build. Contributions should preserve its narrow product identity rather than add IDE breadth.

## Before changing code

1. Read [`AGENTS.md`](AGENTS.md), the canonical [product plan](docs/plans/rafu_product_architecture_plan.md), and the active [phase brief](docs/plans/phases/README.md).
2. Confirm the feature belongs to the active phase and is not one of the explicit non-goals.
3. For a durable architecture choice, open or update an ADR before implementation shape becomes expensive to reverse.
4. Avoid overlapping another worktree's owned paths or unrelated local changes.

## Local checks

```bash
./script/format.sh --lint
swift build
swift test
swift run rafu --help
```

For app, scene, resource, or launch changes, also run:

```bash
./script/build_and_run.sh --verify
```

## Pull requests

Keep one pull request to one bounded outcome. Describe the active phase, owned paths, verification evidence, risks, deferred work, and documentation updates. Add regression tests for behavior and update engineering references whenever implementation reveals a reusable nuance.

Do not include generated `.build`/`dist` products, credentials, source-file samples containing secrets, full diffs in logs, or unrelated formatting churn.

## License status

The project license is not yet selected. Do not add or change licensing headers, dependency-license policy, or contribution terms without an explicit owner decision.

