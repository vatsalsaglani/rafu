// In-process memory footprint via task_info(TASK_VM_INFO), the same number
// `/usr/bin/time -l` reports as "peak memory footprint". Throw-away spike
// code; see .rafu/plans/meeting-speech-spike.md, Answer 3 "Peak memory".
import Darwin

public enum Footprint {
    /// Current `phys_footprint`, in megabytes (MB = bytes / 1_000_000, to
    /// match the plan's reporting convention).
    public static func currentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_000_000.0
    }
}
