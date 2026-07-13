import Darwin.Mach
import Foundation

nonisolated struct ProcessMemorySample: Sendable {
    let residentBytes: UInt64
    let sampledAt: Date

    var formatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(residentBytes), countStyle: .memory)
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
            sampledAt: Date()
        )
    }
}
