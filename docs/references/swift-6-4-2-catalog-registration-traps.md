# Swift 6.4.2 traps when registering json-render catalog entries

- Applies to: `RafuCatalog` (`Sources/RafuApp/Canvas/GeneratedView/RafuCatalog.swift`),
  the `@JRComponent` components under `Components/Board/` and `Components/Document/`,
  and any app code that names `JSONValue`.
- Last verified: Apple Swift 6.4.2, macOS 27, 2026-11-08, with the
  `swift-json-render` package at `0.22.0-alpha.1` (the fix round pins
  `0.22.0-alpha.2`).

## Rule or observed behavior

1. **SILGen crash with `inout Catalog` and typed throws.** The compiler crashes
   (SILGen) when a closure literal, or a reference to a static method, that takes
   `inout Catalog` and has typed throws (`throws(CatalogError)`) is converted to a
   `@Sendable` function type. `RafuCatalog.Entry` is
   `@Sendable (inout Catalog) throws(CatalogError) -> Void`, so an entry written
   as a closure literal or as `SomeType.register` crashes. A **free function**
   with the same signature works. Register each component through a free function
   and put that function in the entry list.
2. **Macro-generated conformance takes the type's isolation.** `@JRComponent`
   generates the `JRComponentType` conformance. Under the app target's default
   `MainActor` isolation the conformance takes the type's main-actor isolation,
   but the catalog is built off the main actor (the MDX bridge needs an off-main
   site). So the components are `nonisolated` shells: the type and its
   `definition` are `nonisolated`, and the SwiftUI body does the main-actor work.
3. **`JSONValue` name clash.** The app already has a `JSONValue`; the package's is
   `JSONRenderCore.JSONValue`. In files that import both, write
   `JSONRenderCore.JSONValue` in full.
4. **Cold build cost.** `JSONRenderClient` pulls `swift-syntax` for the macros.
   Expect a longer cold build and a larger `.build`. No measured time was handed
   over for this note.

## Why it matters

The crash message does not name the cause, and the fix (a free function) looks
like a pointless refactor. The isolation and name traps show up as errors far from
the cause.

## Reproduction or evidence

The crash reproduces when an entry list line is changed from a free function to a
closure literal or `Type.method` reference. A free-function reference compiles.
`RafuCatalogTests.catalogBuilds` fails the build of the catalog instead of
crashing the app at launch.

## Verification

- `./script/build.sh` (0 warnings), then `swift test --filter RafuCatalog`.

## Related code, ADRs, and phases

- `RafuCatalog.swift`, `Components/Board/`, `Components/Document/`
- [ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)
- [`nonisolated-extension-isolation-trap.md`](nonisolated-extension-isolation-trap.md)
- [`swift-6-3-3-release-optimizer-workaround.md`](swift-6-3-3-release-optimizer-workaround.md)
