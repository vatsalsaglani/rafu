# Swift 6.2 memberwise initializer behavior: default-value stored properties

- Applies to: any `struct` with a `let` stored property declared with a default-value initializer (e.g., `let x: T? = nil`)
- Last verified: Swift 6.2 / macOS 26 / 2026-07-25

## Rule or observed behavior

A stored property declared with a default-value initializer is **excluded entirely from the synthesized memberwise initializer**, not merely "included with a default parameter".

For example:
```swift
struct Example: Sendable {
    let required: String
    let optional: String? = nil  // This property is NOT in the synthesized init signature
}

// ERROR: extra argument 'optional' in call
let x = Example(required: "hello", optional: nil)

// Correct: the property has NO parameter in the synthesized init
let x = Example(required: "hello")
```

Calling code that attempts to pass the optional field receives a compiler error: `extra argument 'optional' in call`.

## Why it matters

This behavior is easy to discover accidentally: when refactoring an existing `struct` to add an optional field (a common pattern for backward compatibility or incremental rollout), the property silently becomes unreachable through any initializer. Existing call sites that do not pass the field continue to compile, but any new code attempting to set the field explicitly **fails at build time**.

In the Rafu codebase, where contract types like `TerminalProcessSpec`, `AdapterInvocation`, and `ConductorModelChoice` are frequently extended with optional or defaulted fields, this can silently block setting a new field on an instance after construction.

## Reproduction or evidence

Added `let outputLogURL: URL? = nil` to `TerminalProcessSpec` in `Sources/RafuApp/Conductor/ConductorCore.swift`. Existing call sites (`TerminalProcessSpec(executableURL: ..., arguments: ..., ...)`) continue to compile without change. However, any attempt to pass `outputLogURL` explicitly results in a compiler error:

```swift
let spec = TerminalProcessSpec(
    executableURL: url,
    arguments: ["arg"],
    currentDirectoryPath: "/tmp",
    environment: [:],
    roleBadge: "test",
    outputLogURL: someURL  // ERROR: extra argument 'outputLogURL' in call
)
```

## Verification

The fix is an explicit `init` with the field as a parameter with a default value:

```swift
init(
    executableURL: URL,
    arguments: [String],
    currentDirectoryPath: String,
    environment: [String: String],
    roleBadge: String,
    outputLogURL: URL? = nil
) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.currentDirectoryPath = currentDirectoryPath
    self.environment = environment
    self.roleBadge = roleBadge
    self.outputLogURL = outputLogURL
}
```

This initializer:
- Restores the ability to pass `outputLogURL` explicitly or omit it (the `= nil` default).
- Preserves immutability of the stored property (`let`, not `var`).
- Ensures all existing call sites remain valid because `outputLogURL` has a default value.

Verification: `swift build` exits 0; all call sites compile unchanged; new code can pass `outputLogURL` explicitly.

## Related code, ADRs, and phases

- `Sources/RafuApp/Conductor/ConductorCore.swift` — `TerminalProcessSpec` (lines 428–469), which includes an explicit init comment explaining this behavior
- Ensemble phase C1 implementation (commit 7b4bba0), where this pattern was first needed for the `outputLogURL` field
