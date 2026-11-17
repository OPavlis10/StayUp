import Darwin

/// Paměť podle `host_statistics64`. „Využito" se počítá stejně jako v Monitoru aktivity.
struct MemorySampler {
    /// Fyzická paměť a velikost stránky se za běhu nemění.
    private let total: UInt64?
    private let pageSize: UInt64?

    init() {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        total = sysctlbyname("hw.memsize", &size, &length, nil, 0) == 0 && size > 0 ? size : nil

        var page: vm_size_t = 0
        pageSize = host_page_size(MachHost.port, &page) == KERN_SUCCESS && page > 0 ? UInt64(page) : nil
    }

    func sample() -> MemoryMetrics? {
        guard let total, let pageSize else { return nil }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(MachHost.port, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Paměť aplikací = anonymní (internal) stránky bez uvolnitelných (purgeable).
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages >= purgeable ? internalPages - purgeable : 0
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)

        let compressed = compressedPages * pageSize
        let used = min((appPages + wiredPages + compressedPages) * pageSize, total)
        return MemoryMetrics(total: total,
                             used: used,
                             free: total - used,
                             compressed: min(compressed, total),
                             pressure: Self.pressure())
    }

    private static func pressure() -> MemoryPressure? {
        var level: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0 else { return nil }
        return MemoryPressure(rawValue: Int(level))
    }
}
