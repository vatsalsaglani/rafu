import Darwin
import Foundation

/// Tracks OS processes Rafu itself spawns (terminal shells, `git`, later
/// language servers) so the Resources surface (increment 1) can show
/// per-process resident memory without shelling out to `ps`. Actor-isolated
/// so registration from the terminal controller and sampling from the
/// Resources view never race.
actor ProcessResourceRegistry {
    /// The process-wide instance. Canonical for cross-lane use: lane 1
    /// registers terminal shells here, and lane 2 will register language
    /// servers into this same instance so the Resources surface stays a
    /// single source of truth for every process Rafu spawns.
    static let shared = ProcessResourceRegistry()

    nonisolated enum ProcessKind: Sendable {
        case terminalShell
        case git
        case languageServer
        case other
    }

    /// One sampled row. `residentBytes` is `nil` when the pid has already
    /// exited; the row is still returned (not dropped) so a process that
    /// died mid-sample doesn't flicker out of the list before its owner
    /// calls `unregister(id:)`.
    nonisolated struct ProcessResourceSample: Sendable {
        let id: UUID
        let name: String
        let kind: ProcessKind
        let pid: pid_t
        let residentBytes: UInt64?
    }

    private struct Entry {
        let name: String
        let kind: ProcessKind
        let pid: pid_t
    }

    private var entries: [UUID: Entry] = [:]

    /// Registers a process for sampling. Last write wins: registering the
    /// same `id` again (e.g. a terminal tab respawning its shell) replaces
    /// the previous entry rather than accumulating duplicates.
    func register(id: UUID, name: String, kind: ProcessKind, pid: pid_t) {
        entries[id] = Entry(name: name, kind: kind, pid: pid)
    }

    /// Unregisters a process. An unknown `id` is a no-op — callers don't
    /// need to track whether they already unregistered.
    func unregister(id: UUID) {
        entries[id] = nil
    }

    /// Samples resident memory for every registered process.
    func sample() -> [ProcessResourceSample] {
        entries.map { id, entry in
            ProcessResourceSample(
                id: id,
                name: entry.name,
                kind: entry.kind,
                pid: entry.pid,
                residentBytes: Self.residentBytes(for: entry.pid)
            )
        }
    }

    private static func residentBytes(for pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? info.ri_resident_size : nil
    }
}
