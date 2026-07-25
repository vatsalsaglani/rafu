import Foundation
import Observation

/// What a timeline entry marks. Presentation-and-attribution only: the kind
/// says WHAT THE APP DID at the moment resident memory was sampled, never
/// "this subsystem owns N bytes" — see `MemoryTimeline`'s honesty contract.
nonisolated enum MemoryEventKind: String, Sendable, CaseIterable {
    case documentOpened
    case documentClosed
    case documentsHibernated
    case terminalOpened
    case terminalClosed
    case gitRefreshed
    case diffOpened
    case diffClosed
    case searchCompleted
    case fileIndexBuilt
    case fileIndexShed
    case memoryPressure
    /// A periodic reading taken only while the Resources popover is open.
    /// Carries no event of its own: it exists so the sparkline has
    /// resolution and so a spike's settling is visible after the fact.
    case sample

    var title: String {
        switch self {
        case .documentOpened: return "Opened file"
        case .documentClosed: return "Closed file"
        case .documentsHibernated: return "Hibernated tabs"
        case .terminalOpened: return "Opened terminal"
        case .terminalClosed: return "Closed terminal"
        case .gitRefreshed: return "Git refresh"
        case .diffOpened: return "Opened diff"
        case .diffClosed: return "Closed diff"
        case .searchCompleted: return "Search"
        case .fileIndexBuilt: return "File index built"
        case .fileIndexShed: return "File index shed"
        case .memoryPressure: return "Memory pressure"
        case .sample: return "Reading"
        }
    }

    /// Shape-distinct SF Symbols — the timeline never conveys anything by
    /// color alone (AGENTS.md macOS interface rules).
    var symbol: String {
        switch self {
        case .documentOpened, .documentClosed: return "doc.text"
        case .documentsHibernated: return "moon.zzz"
        case .terminalOpened, .terminalClosed: return "terminal"
        case .gitRefreshed: return "arrow.triangle.branch"
        case .diffOpened, .diffClosed: return "plusminus"
        case .searchCompleted: return "magnifyingglass"
        case .fileIndexBuilt, .fileIndexShed: return "list.bullet.indent"
        case .memoryPressure: return "exclamationmark.triangle"
        case .sample: return "circle.dotted"
        }
    }
}

/// One resident-memory reading, annotated with what the app had just done.
nonisolated struct MemoryTimelineEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let kind: MemoryEventKind
    /// Short, user-recognizable context ("Foo.swift", "Terminal 2", "3 tabs").
    /// Never document text, never a full path, never persisted or logged.
    let detail: String
    /// Which window the event came from, as its workspace display name.
    /// Empty for app-level events that belong to no window (memory
    /// pressure). Every Rafu window shares one process and therefore one
    /// timeline, so without this a row filed by another window is
    /// indistinguishable from one the user just caused here.
    let source: String
    let residentBytes: UInt64
    /// Change in whole-process resident memory since the previous reading.
    /// This is a CORRELATION over the interval, not this event's cost.
    let deltaBytes: Int64
    let at: Date
}

/// Pure timeline arithmetic and formatting, kept out of the observable model
/// so every rule is unit-testable without sampling a live process.
nonisolated enum MemoryTimelinePolicy {
    /// Signed change between two unsigned readings. `nil` previous (the
    /// first reading of the session) is a zero delta rather than a fake
    /// jump from zero — there is no earlier measurement to compare against.
    static func delta(from previous: UInt64?, to current: UInt64) -> Int64 {
        guard let previous else { return 0 }
        return Int64(bitPattern: current) - Int64(bitPattern: previous)
    }

    /// Appends to a bounded ring buffer, dropping oldest-first. A `cap` of 0
    /// or less keeps nothing.
    static func appending<Element>(_ element: Element, to buffer: [Element], cap: Int)
        -> [Element]
    {
        guard cap > 0 else { return [] }
        var next = buffer
        next.append(element)
        if next.count > cap {
            next.removeFirst(next.count - cap)
        }
        return next
    }

    /// Signed MB/GB label for a delta, e.g. `+18.2 MB`, `-4.0 MB`, `0 MB`.
    /// Locale-independent (`String(format:)`, POSIX `%f`) for the same
    /// reason `ResourceMemoryFormat` is — deterministic across decimal
    /// separators.
    static func deltaLabel(_ bytes: Int64) -> String {
        let magnitude = ResourceMemoryFormat.label(UInt64(bytes.magnitude))
        if bytes > 0 { return "+" + magnitude }
        if bytes < 0 { return "-" + magnitude }
        return "0 MB"
    }

    /// Symbol for a delta's direction — the non-color channel for "went up"
    /// vs "went down".
    static func deltaSymbol(_ bytes: Int64) -> String {
        if bytes > 0 { return "arrow.up" }
        if bytes < 0 { return "arrow.down" }
        return "equal"
    }

    /// The secondary line under an event's title: its detail, plus the
    /// originating window when that is NOT the window doing the asking.
    ///
    /// One process holds every Rafu window, so one timeline holds every
    /// window's events. Without this, a row filed while the user was working
    /// in another window is indistinguishable from one they just caused
    /// here. The current window's own rows stay unannotated — labelling
    /// every row "in <this workspace>" is noise that buries the few rows
    /// that genuinely came from elsewhere.
    ///
    /// Granularity is the WORKSPACE name, so two windows open on the same
    /// workspace still read alike. That is the honest limit of what the
    /// event sites know; distinguishing them would need window identity
    /// threaded through every call site for a case that reads correctly
    /// either way ("it happened in that project").
    static func subtitle(for entry: MemoryTimelineEntry, currentWindow: String) -> String {
        let isForeign = !entry.source.isEmpty && entry.source != currentWindow
        let parts = [entry.detail, isForeign ? "in \(entry.source)" : ""]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Normalizes readings into 0…1 for the sparkline, where 0 is the
    /// smallest reading in the window and 1 the largest. A flat or
    /// single-point series maps to a mid-line (0.5) rather than dividing by
    /// a zero range — a flat graph is the honest picture of flat memory.
    static func normalized(_ readings: [UInt64]) -> [Double] {
        guard let low = readings.min(), let high = readings.max() else { return [] }
        guard high > low else { return readings.map { _ in 0.5 } }
        let range = Double(high - low)
        return readings.map { Double($0 - low) / range }
    }
}

/// Process-wide resident-memory timeline: a bounded, in-memory ring of
/// readings annotated with what the app had just finished doing.
///
/// **Honesty contract.** macOS exposes no per-subsystem breakdown of a
/// task's own resident size — `mach_task_basic_info` is one number for the
/// whole process. So this type NEVER claims "opening that diff cost 18 MB."
/// It records "resident memory moved +18 MB across the interval that ended
/// when the diff finished opening," which is a correlation the user can act
/// on. Allocator slack, framework caches, and lazy deallocation all land in
/// the same number, and a release can show up several readings after the
/// work that caused it.
///
/// **No standing poll.** Readings are taken at event time (`record`), which
/// is a single cheap `task_info` syscall on an already-running main-actor
/// path — not a timer. The only periodic readings come from the Resources
/// popover's existing visible-only `.task` loop, which stops when the
/// popover closes. This preserves the "no standing background poll" result
/// recorded in `memory-caps-and-pressure.md`.
///
/// **Privacy.** `detail` carries file names and terminal titles only — the
/// same strings already visible in tab labels. Nothing here is persisted,
/// logged, or transmitted; the whole ring dies with the process.
@Observable
@MainActor
final class MemoryTimeline {
    /// Process-wide instance, mirroring `ProcessResourceRegistry.shared` and
    /// `MemoryPressureMonitor.shared`. Resident memory is a property of the
    /// process, not of a window, so every window's Resources popover reads
    /// this same ring.
    static let shared = MemoryTimeline()

    /// Events kept for the timeline list. ~120 covers a long working
    /// session's worth of real activity at a few hundred bytes each.
    static let eventCap = 120
    /// Readings kept for the sparkline, including periodic ones.
    static let readingCap = 180

    private(set) var events: [MemoryTimelineEntry] = []
    /// Every reading, event-driven and periodic, oldest first — the
    /// sparkline's series.
    private(set) var readings: [UInt64] = []

    @ObservationIgnored
    private var lastResident: UInt64?

    /// Injectable so tests drive the ring with scripted readings instead of
    /// this process's real, unrepeatable resident size.
    @ObservationIgnored
    var sampleResident: () -> UInt64? = { ProcessMemorySampler().sample()?.residentBytes }

    /// Internal (not `private`) so tests build their own instance — hermetic
    /// under parallel runs, unlike mutating `.shared`.
    init() {}

    /// Takes a reading and, for everything but `.sample`, files an event
    /// against it.
    ///
    /// Call this AFTER the work completes, not before: the reading is taken
    /// synchronously here, so a call placed ahead of the allocation it means
    /// to describe attributes the cost to the following entry instead.
    func record(_ kind: MemoryEventKind, detail: String = "", source: String = "") {
        guard let resident = sampleResident() else { return }
        let delta = MemoryTimelinePolicy.delta(from: lastResident, to: resident)
        lastResident = resident
        readings = MemoryTimelinePolicy.appending(resident, to: readings, cap: Self.readingCap)
        guard kind != .sample else { return }
        let entry = MemoryTimelineEntry(
            id: UUID(),
            kind: kind,
            detail: detail,
            source: source,
            residentBytes: resident,
            deltaBytes: delta,
            at: Date()
        )
        events = MemoryTimelinePolicy.appending(entry, to: events, cap: Self.eventCap)
    }

    /// How long to let an action settle before reading resident memory.
    ///
    /// Most of what an action costs is allocated AFTER the call that starts
    /// it returns: opening a tab registers the document synchronously, but
    /// SwiftUI mounts the `NSTextView`, TextKit builds the storage, and the
    /// highlighter parses on later turns. Reading at the call site would
    /// attribute a spike to whatever event happens to come next. A short
    /// settle window catches the common case without pretending to be
    /// exact — lazy deallocation and off-main parsing can still land later,
    /// which is why the UI labels these as interval changes.
    static let settleDelay = Duration.milliseconds(400)

    /// The event API for call sites: files `kind` with a reading taken after
    /// `settleDelay`. One-shot per call — an event-driven delay, not a
    /// timer, so the "no standing background poll" invariant holds.
    func note(_ kind: MemoryEventKind, detail: String = "", source: String = "") {
        Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            self?.record(kind, detail: detail, source: source)
        }
    }

    /// The Resources popover's periodic reading — resolution for the
    /// sparkline without an event row.
    func recordPeriodicReading() {
        record(.sample)
    }

    /// Newest-first, the order the timeline list renders in.
    var recentEvents: [MemoryTimelineEntry] {
        events.reversed()
    }

    func clear() {
        events = []
        readings = []
        lastResident = nil
    }
}
