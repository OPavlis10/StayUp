import Darwin

/// Sdílený port hostitele. `mach_host_self()` při každém volání přidává referenci, proto se bere jen jednou.
enum MachHost {
    static let port: mach_port_t = mach_host_self()
}

/// Využití CPU z rozdílu tiků mezi dvěma vzorky (`host_processor_info`).
struct CPUSampler {
    private struct Ticks {
        var busy: UInt32
        var idle: UInt32
    }

    private var previous: [Ticks]?

    init() {}

    /// První volání (zatím není s čím porovnat) vrací `nil`, stejně jako selhání systémového volání.
    mutating func sample() -> CPUMetrics? {
        guard let current = Self.readTicks() else {
            previous = nil
            return nil
        }
        defer { previous = current }
        guard let previous, previous.count == current.count, !current.isEmpty else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var busySum: UInt64 = 0
        var allSum: UInt64 = 0
        for (now, before) in zip(current, previous) {
            // Čítače jsou 32bitové; &- správně přenese i přetečení.
            let busy = UInt64(now.busy &- before.busy)
            let idle = UInt64(now.idle &- before.idle)
            let all = busy + idle
            perCore.append(all > 0 ? Double(busy) / Double(all) : 0)
            busySum += busy
            allSum += all
        }
        // Mezi vzorky neuběhl žádný tik: nelze nic tvrdit.
        guard allSum > 0 else { return nil }
        return CPUMetrics(total: Double(busySum) / Double(allSum), perCore: perCore)
    }

    private static func readTicks() -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(MachHost.port, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            // Pole alokovalo jádro do našeho adresního prostoru, musíme ho vrátit.
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        let count = Int(cpuCount)
        guard count > 0, Int(infoCount) >= count * states else { return nil }

        var result: [Ticks] = []
        result.reserveCapacity(count)
        for core in 0..<count {
            let base = core * states
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            let busy = tick(CPU_STATE_USER) &+ tick(CPU_STATE_SYSTEM) &+ tick(CPU_STATE_NICE)
            result.append(Ticks(busy: busy, idle: tick(CPU_STATE_IDLE)))
        }
        return result
    }
}
