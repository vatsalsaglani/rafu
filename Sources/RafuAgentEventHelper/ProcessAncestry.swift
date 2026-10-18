import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// The helper's parent PIDs, nearest first. Only PIDs are read: no command
/// lines, no environment, no executable paths. The app uses the chain to find
/// the Rafu terminal whose shell started the agent.
enum ProcessAncestry {
    static func parentChain(limit: Int) -> [Int32] {
        var chain: [Int32] = []
        var pid = getppid()
        var visited = Set<pid_t>()
        while chain.count < limit, pid > 1, visited.insert(pid).inserted {
            chain.append(Int32(pid))
            guard let parent = parent(of: pid) else { break }
            pid = parent
        }
        return chain
    }

    #if canImport(Darwin)
        private static func parent(of pid: pid_t) -> pid_t? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return pid_t(info.pbi_ppid)
        }
    #else
        private static func parent(of pid: pid_t) -> pid_t? { nil }
    #endif
}
