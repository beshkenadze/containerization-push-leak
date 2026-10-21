import Darwin

struct MemorySample: Sendable {
    let physFootprint: UInt64
    let lifetimePeak: UInt64
    let mallocInUse: UInt64

    static func now() -> MemorySample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(kr == KERN_SUCCESS, "task_info(TASK_VM_INFO) failed: \(kr)")

        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)

        return MemorySample(
            physFootprint: info.phys_footprint,
            lifetimePeak: UInt64(info.ledger_phys_footprint_peak),
            mallocInUse: UInt64(stats.size_in_use)
        )
    }
}

@discardableResult
func relieveMallocPressure() -> Int {
    malloc_zone_pressure_relief(nil, 0)
}

func mib(_ bytes: some BinaryInteger) -> Double {
    (Double(bytes) / 1_048_576 * 10).rounded() / 10
}

func mibDelta(_ value: UInt64, from base: UInt64) -> Double {
    mib(Int64(value) - Int64(base))
}
