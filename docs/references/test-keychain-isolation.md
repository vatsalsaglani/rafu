# Tests must not reach the real Keychain (usage credentials)

- Applies to: any test that builds a `UsageRegistryReader`, or that calls
  something that refreshes usage (for example `NotchCompanionModel.clicked()`,
  which pins the panel and triggers a usage refresh).
- Last verified: Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
  (26A434), 2026-10-19.

## Rule or observed behavior

`UsageRegistryReader`'s production defaults resolve credentials through
`productionCredentials` -> `UsageCredentialStore.credential(for:)` ->
`SecItemCopyMatching`. A test that uses those defaults reads the real login
Keychain of whoever runs it.

On a Mac where Rafu has stored usage credentials, the unsigned
`swift-testing` helper process cannot satisfy the Keychain access prompt, so
the call blocks. The full parallel and serial suites hung for more than one
hour at 0% CPU. CI runners have no such items, so CI never showed the hang.

Rule: every test that constructs a `UsageRegistryReader` must pass both
`resolveCredentials: { _, _ in [:] }` and `hasNetworkConsent:` (and
`isEnabled:` when the default would read user preferences). This also applies
to tests that do not build a reader themselves but reach one through a model:
`clicked()` pins the panel and triggers a usage refresh, so such a test must
first assign a fixture reader to the model.

Fixed call sites (2026-10-19):

- `NotchCompanionModelTests`: the private `fixtureReader(descriptors:)` and
  `fixtureReader(providerIDs:)` helpers, and the two tests that call
  `clicked()`.
- `NotchCompanionFeedTests.arbitrationFollowsModelHoverState`.

`UsageCoreTests` already injected `resolveCredentials` in every reader it
builds.

## Why it matters

The failure appears only on a developer machine that has used Rafu's usage
cards, and it looks like a hung build or a deadlock: no output, no CPU. An
agent that sees a silent `swift test` may blame `.build/.lock` (see
[`build-and-run.md`](build-and-run.md)) or the scheduler. A test must not read
user secrets at all (AGENTS.md: secrets live in Keychain and are never logged
or fixtured).

## Reproduction or evidence

Sample the stuck helper and look for the Keychain call:

```bash
sample <swiftpm-testing-helper pid> 2
```

The stack ended in `SecurityServer::ClientSession::decrypt` -> `mach_msg`,
with `SecItemCopyMatching` above it. A hang with 0% CPU and that stack is this
problem, not a lock or a slow test.

## Verification

```bash
./script/test.sh --filter NotchCompanionModelTests
./script/test.sh --filter NotchCompanionFeedTests
```

After the fix the full suites completed on main (2026-10-19): parallel mode,
250 + 2522 tests passed; `--no-parallel` (CI mode), 250 + 2522 passed. They
ran on the same Mac that hung before the fix, which holds stored usage
credentials, so the passing run is a real regression check.

## Related code, ADRs, and phases

- `Sources/RafuApp/Usage/UsageRegistryReader.swift`
- `Tests/RafuAppTests/NotchCompanionModelTests.swift`,
  `Tests/RafuAppTests/NotchCompanionFeedTests.swift`,
  `Tests/RafuAppTests/Usage/UsageCoreTests.swift`
- [`usage-provider-contract.md`](usage-provider-contract.md)
- [`test-source-policy-and-bookmark-isolation.md`](test-source-policy-and-bookmark-isolation.md)
- ADR 0017, ADR 0027
