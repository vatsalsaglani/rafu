import Foundation

/// Runs `body` inside an Objective-C autorelease pool where one exists, and
/// calls it directly elsewhere.
///
/// Swift concurrency drains the thread's autorelease pool only when a job
/// ends. A long synchronous loop (one file, line, or symbol per pass, with no
/// `await`) therefore keeps every autoreleased Foundation object alive until
/// the whole loop ends. `JSONSerialization` trees and `FileHandle` data are
/// such objects. Wrap one unit of work per pass so the objects are freed at
/// once and the malloc zone does not grow to the peak.
///
/// The body is synchronous on purpose: no `await` can run inside a pool.
/// A value that the body returns is retained by Swift before the pool drains,
/// so it stays valid. See `docs/references/memory-caps-and-pressure.md`.
@inline(__always)
public func withAutoreleasePool<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
    #else
        return try body()
    #endif
}
