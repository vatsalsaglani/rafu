import Darwin.Mach
import Foundation

nonisolated struct ProcessMemorySample: Sendable {
    let residentBytes: UInt64
    /// `phys_footprint` from `TASK_VM_INFO`: the number Activity Monitor's
    /// Memory column and the idle-memory budget use. Resident size also
    /// counts clean shared pages (frameworks, mapped files), so it reads
    /// differently. `nil` when the kernel does not report it.
    var footprintBytes: UInt64?
    let sampledAt: Date

    /// The figure to show for Rafu itself: the footprint, else resident size.
    var displayBytes: UInt64 { footprintBytes ?? residentBytes }

    var formatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(displayBytes), countStyle: .memory)
    }
}

nonisolated struct ProcessMemorySampler: Sendable {
    func sample() -> ProcessMemorySample? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return ProcessMemorySample(
            residentBytes: UInt64(info.resident_size),
            footprintBytes: Self.footprint(),
            sampledAt: Date()
        )
    }

    /// This process's `phys_footprint`, or `nil` if `TASK_VM_INFO` fails.
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}
