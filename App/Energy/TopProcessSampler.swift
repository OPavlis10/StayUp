import Darwin
import Foundation

/// Žebříček procesů podle CPU a energie z rozdílů `proc_pid_rusage` mezi dvěma čteními.
///
/// Bez oprávnění jdou přečíst jen procesy přihlášeného uživatele (`proc_pid_rusage` na cizí proces
/// vrací EPERM); systémové procesy (WindowServer, kernel_task, mds…) v žebříčku chybí – viz
/// `TopProcessesSnapshot.isLimitedToCurrentUser`.
///
/// Kvůli ceně se každý vzorek nečtou všechny procesy: nové a ty, které něco dělají, se čtou pokaždé,
/// nečinné jen každý čtvrtý vzorek (střídavě po čtvrtinách). Každý proces má vlastní časovou značku,
/// takže jeho průměr je správný i za delší úsek – dosud nečinný proces, který se rozběhne, se jen
/// v žebříčku objeví se zpožděním (při 5 s nejvýš 20 s). První žebříček po otevření panelu
/// vychází z přečtení všech procesů.
/// Určeno jen pro otevřený panel, zhruba každých 5 s. Krátce žijící procesy, které vzniknou i skončí
/// mezi dvěma vzorky, zachytit nelze.
struct TopProcessSampler {
    private struct ProcessState {
        /// Čas startu procesu; odliší nový proces se stejným PID.
        var start: UInt64
        /// user + system v jednotkách mach času.
        var cpuTicks: UInt64
        /// Nanojouly.
        var energy: UInt64
        /// Kdy byl proces naposledy čten (mach čas).
        var polledAt: UInt64
        /// Průměr za poslední úsek mezi dvěma čteními: procenta jednoho jádra a watty.
        var cpuPercent: Float
        var watts: Float
        /// Má už aspoň jeden platný úsek (dvě čtení)?
        var rated: Bool
        var group: Int
        /// Pořadové číslo vzorku, ve kterém byl proces naposledy v seznamu.
        var seen: UInt32
    }

    private struct Group {
        var key: String
        var fallbackName: String
        /// Cesta k balíčku `.app`, pokud proces do nějakého patří.
        var bundlePath: String?
        var displayName: String?
    }

    private struct Usage {
        var cpuPercent: Double = 0
        var watts: Double = 0
        var count: Int = 0
    }

    /// Od kolika procent jádra se proces čte každý vzorek.
    private static let activeThreshold: Float = 0.2

    /// Po delší pauze (panel byl zavřený) se začne znovu – jinak by to byl průměr za celou pauzu.
    private let maxInterval: TimeInterval
    /// Nečinné procesy se čtou jednou za tolik vzorků (1 = všechny pokaždé).
    private let idleStride: UInt32
    /// Kolik procesů se při posledním vzorku skutečně četlo (pro měření ceny).
    private(set) var lastPolledCount = 0
    private var states: [pid_t: ProcessState] = [:]
    private var lastTicks: UInt64?
    private var generation: UInt32 = 0
    private var energyAvailable = false
    private var pids = [pid_t](repeating: 0, count: 2048)
    /// Pracovní pole součtů podle čísla skupiny a seznam skupin, kterých se vzorek dotkl.
    private var usage: [Usage] = []
    private var touched: [Int] = []
    private var groups: [Group] = []
    private var groupIndex: [String: Int] = [:]
    /// Lokalizované názvy aplikací podle cesty k balíčku; přežijí `reset()`, protože první dotaz
    /// na název je drahý (desítky ms).
    private var nameCache: [String: String] = [:]
    private var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    /// Převod mach času na nanosekundy (na Apple Silicon 125/3, na Intelu 1/1).
    private let nanosPerTick: Double

    init(maxInterval: TimeInterval = 15, idleStride: Int = 4) {
        self.maxInterval = maxInterval
        self.idleStride = UInt32(max(idleStride, 1))
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosPerTick = timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }

    /// Zahodí výchozí stav; další `sample()` jen nabere nový a vrátí `nil`. Volat při zavření panelu.
    mutating func reset() {
        states.removeAll(keepingCapacity: true)
        lastTicks = nil
        energyAvailable = false
        usage.removeAll(keepingCapacity: true)
        touched.removeAll(keepingCapacity: true)
        groups.removeAll(keepingCapacity: true)
        groupIndex.removeAll(keepingCapacity: true)
    }

    /// První volání (a volání po delší pauze) vrací `nil` – není s čím porovnat.
    mutating func sample(limit: Int = 5) -> TopProcessesSnapshot? {
        // mach_absolute_time se ve spánku zastaví, stejně jako čas CPU.
        let now = mach_absolute_time()
        var comparable = false
        var previousSample = now
        if let last = lastTicks {
            let elapsed = Double(now &- last) * nanosPerTick / 1e9
            if elapsed > maxInterval {
                reset()
            } else {
                comparable = true
                previousSample = last
            }
        }

        // Jen procesy přihlášeného uživatele: dotaz na cizí proces stejně skončí EPERM
        // a neúspěšné volání je dražší než úspěšné.
        let pidCount = listPIDs()
        guard pidCount > 0 else {
            reset()
            return nil
        }
        let totalCount = max(Int(proc_listallpids(nil, 0)), pidCount)

        generation &+= 1
        let slot = generation % idleStride
        var live = 0
        var polled = 0
        var info = rusage_info_v6()

        for index in 0..<pidCount {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let known = states.index(forKey: pid)
            if let known {
                let state = states.values[known]
                // Nečinný proces mimo svou čtvrtinu: nechat poslední známé hodnoty.
                if state.rated, state.cpuPercent < Self.activeThreshold,
                   UInt32(truncatingIfNeeded: pid) % idleStride != slot {
                    states.values[known].seen = generation
                    live += 1
                    continue
                }
            }

            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            polled += 1
            // Právě skončený proces vrací ESRCH; ze stavu zmizí při úklidu níž.
            guard status == 0 else { continue }
            live += 1

            let cpuTicks = info.ri_user_time &+ info.ri_system_time
            // ri_energy_nj je novější počítadlo; ri_billed_energy je záloha pro případ, že je nulové.
            let energy = info.ri_energy_nj > 0 ? info.ri_energy_nj : info.ri_billed_energy
            if energy > 0 { energyAvailable = true }
            let start = info.ri_proc_start_abstime

            var next = ProcessState(start: start, cpuTicks: cpuTicks, energy: energy, polledAt: now,
                                    cpuPercent: 0, watts: 0, rated: false, group: 0, seen: generation)
            if let known, states.values[known].start == start {
                let before = states.values[known]
                next.group = before.group
                let window = Double(now &- before.polledAt) * nanosPerTick
                // Počítadla jen rostou; kdyby ne, úsek se nezapočítá.
                if window > 0, cpuTicks >= before.cpuTicks, energy >= before.energy {
                    next.cpuPercent = Float(Double(cpuTicks - before.cpuTicks) * nanosPerTick / window * 100)
                    next.watts = Float(Double(energy - before.energy) / window)
                    next.rated = true
                }
                states.values[known] = next
            } else {
                next.group = groupID(for: pid)
                // Proces spuštěný až po minulém vzorku: všechno, co dosud spotřeboval, patří do tohoto úseku.
                let window = Double(now &- previousSample) * nanosPerTick
                if comparable, start >= previousSample, window > 0 {
                    next.cpuPercent = Float(Double(cpuTicks) * nanosPerTick / window * 100)
                    next.watts = Float(Double(energy) / window)
                    next.rated = true
                }
                states[pid] = next
            }
        }

        // Skončené procesy pryč, ať mapa neroste.
        if states.count > live {
            let current = generation
            states = states.filter { $0.value.seen == current }
        }
        lastTicks = now
        lastPolledCount = polled
        guard comparable else {
            pruneGroupsIfNeeded()
            return nil
        }

        // Součty podle skupin z posledních známých hodnot všech procesů.
        if usage.count < groups.count {
            usage.append(contentsOf: repeatElement(Usage(), count: groups.count - usage.count))
        }
        var totalCPU = 0.0
        var totalWatts = 0.0
        for state in states.values where state.rated && (state.cpuPercent > 0 || state.watts > 0) {
            if usage[state.group].count == 0 { touched.append(state.group) }
            usage[state.group].cpuPercent += Double(state.cpuPercent)
            usage[state.group].watts += Double(state.watts)
            usage[state.group].count += 1
            totalCPU += Double(state.cpuPercent)
            totalWatts += Double(state.watts)
        }

        let ranking: ProcessRanking = energyAvailable ? .power : .cpu
        var ranked: [(id: Int, used: Usage)] = []
        ranked.reserveCapacity(touched.count)
        for id in touched {
            ranked.append((id, usage[id]))
            usage[id] = Usage()
        }
        touched.removeAll(keepingCapacity: true)
        ranked.sort { left, right in
            let (a, b) = (left.used, right.used)
            if ranking == .power, a.watts != b.watts { return a.watts > b.watts }
            if a.cpuPercent != b.cpuPercent { return a.cpuPercent > b.cpuPercent }
            return left.id < right.id
        }

        var entries: [ProcessEnergyEntry] = []
        entries.reserveCapacity(limit)
        for (id, used) in ranked.prefix(max(limit, 0)) {
            entries.append(ProcessEnergyEntry(id: groups[id].key,
                                              name: displayName(forGroup: id),
                                              cpuPercent: used.cpuPercent,
                                              watts: energyAvailable ? used.watts : nil,
                                              processCount: used.count))
        }
        pruneGroupsIfNeeded()
        return TopProcessesSnapshot(entries: entries,
                                    ranking: ranking,
                                    totalCPUPercent: totalCPU,
                                    totalWatts: energyAvailable ? totalWatts : nil,
                                    readableProcessCount: live,
                                    totalProcessCount: totalCount,
                                    interval: Double(now &- previousSample) * nanosPerTick / 1e9)
    }

    // MARK: - Seznam procesů

    private mutating func listPIDs() -> Int {
        while true {
            let capacity = pids.count
            let count = pids.withUnsafeMutableBytes { buffer in
                // Vrací počet zapsaných bajtů.
                Int(proc_listpids(UInt32(PROC_UID_ONLY), getuid(), buffer.baseAddress, Int32(buffer.count)))
                    / MemoryLayout<pid_t>.stride
            }
            guard count > 0 else { return 0 }
            // Plné pole může znamenat, že se všechno nevešlo.
            if count < capacity || capacity >= 65536 { return min(count, capacity) }
            pids = [pid_t](repeating: 0, count: capacity * 2)
        }
    }

    // MARK: - Skupiny

    /// Cesta ke spustitelnému souboru se čte jen jednou za život procesu.
    private mutating func groupID(for pid: pid_t) -> Int {
        let length = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            Int(proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count)))
        }
        let path: String
        if length > 0 {
            path = pathBuffer.withUnsafeBufferPointer { buffer in
                String(decoding: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[0..<length]), as: UTF8.self)
            }
        } else {
            path = ""
        }

        let key: String
        var bundlePath: String?
        let fallbackName: String
        if path.isEmpty {
            // Cestu se nepodařilo zjistit: zkusit aspoň krátký název procesu.
            let nameLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
                Int(proc_name(pid, buffer.baseAddress, UInt32(buffer.count)))
            }
            let name = nameLength > 0 ? pathBuffer.withUnsafeBufferPointer { buffer in
                String(decoding: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[0..<nameLength]), as: UTF8.self)
            } : "pid \(pid)"
            key = "?/" + name
            fallbackName = name
        } else if let range = path.range(of: ".app/") {
            // Vnější balíček: pomocné procesy (…/Frameworks/…/Helper.app/…) spadnou pod svou aplikaci.
            let bundle = String(path[..<range.lowerBound]) + ".app"
            key = bundle
            bundlePath = bundle
            fallbackName = Self.lastComponent(of: String(path[..<range.lowerBound]))
        } else {
            key = path
            fallbackName = Self.lastComponent(of: path)
        }

        if let existing = groupIndex[key] { return existing }
        groups.append(Group(key: key, fallbackName: fallbackName, bundlePath: bundlePath, displayName: nil))
        groupIndex[key] = groups.count - 1
        return groups.count - 1
    }

    private static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = String(path[path.index(after: slash)...])
        return name.isEmpty ? path : name
    }

    /// Lokalizovaný název aplikace se zjišťuje jen pro zobrazené položky a pamatuje se.
    private mutating func displayName(forGroup id: Int) -> String {
        if let name = groups[id].displayName { return name }
        var name = groups[id].fallbackName
        if let bundlePath = groups[id].bundlePath {
            if let cached = nameCache[bundlePath] {
                name = cached
            } else {
                let localized = FileManager.default.displayName(atPath: bundlePath)
                if !localized.isEmpty {
                    name = localized.hasSuffix(".app") ? String(localized.dropLast(4)) : localized
                }
                if nameCache.count >= 128 { nameCache.removeAll(keepingCapacity: true) }
                nameCache[bundlePath] = name
            }
        }
        groups[id].displayName = name
        return name
    }

    /// Tabulka skupin nesmí růst donekonečna: občas se vyhodí skupiny bez živého procesu.
    private mutating func pruneGroupsIfNeeded() {
        guard groups.count > 256, groups.count > states.count * 2 else { return }
        var live = Set<Int>()
        for state in states.values { live.insert(state.group) }
        var remap: [Int: Int] = [:]
        var kept: [Group] = []
        kept.reserveCapacity(live.count)
        for (index, group) in groups.enumerated() where live.contains(index) {
            remap[index] = kept.count
            kept.append(group)
        }
        groups = kept
        usage.removeAll(keepingCapacity: true)
        groupIndex.removeAll(keepingCapacity: true)
        for (index, group) in groups.enumerated() { groupIndex[group.key] = index }
        for pid in Array(states.keys) {
            if let old = states[pid]?.group, let new = remap[old] { states[pid]?.group = new }
        }
    }
}
