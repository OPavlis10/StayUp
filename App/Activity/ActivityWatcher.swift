import Darwin
import Foundation

/// Monotónní hodiny, které během spánku Macu **stojí** (`CLOCK_UPTIME_RAW`).
/// Spánek se tak nikdy nezapočítá do nečinnosti ani do jmenovatele vytížení.
enum ActivityClock {
    static func uptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// Jedna skupina sledovaných procesů se stejným názvem (pro zobrazení).
struct ActivityProcessGroup: Sendable, Equatable {
    /// Název spustitelného souboru, např. `Claude Helper (Renderer)`.
    let name: String
    /// Kolik procesů toho názvu běží.
    let count: Int
    /// Součet za skupinu v procentech jednoho jádra; `nil`, dokud není s čím porovnat.
    let cpuPercent: Double?
}

/// Výsledek jednoho vzorku sledování.
struct ActivitySample: Sendable, Equatable {
    /// Čas vzorku podle `ActivityClock.uptime()`.
    let uptime: TimeInterval
    /// Počet procesů, které vyhověly vzorům (bez této aplikace).
    let matchedCount: Int
    /// Z toho procesy, jejichž čas CPU nešel přečíst (cizí uživatel); do součtu se nepočítají.
    let unreadableCount: Int
    /// Součet času CPU všech vyhovujících procesů za dobu od předchozího vzorku, v procentech jednoho jádra
    /// (200 = dvě plně vytížená jádra). `nil` u prvního vzorku a po změně nastavení.
    let cpuPercent: Double?
    /// Práh, se kterým se porovnávalo (procenta jednoho jádra).
    let thresholdPercent: Double
    /// `cpuPercent >= thresholdPercent`; `nil`, když `cpuPercent` není známé.
    let isWorking: Bool?
    /// Nejvytíženější skupiny podle názvu, nejvýš `ActivityWatcher.topGroupLimit`.
    let topGroups: [ActivityProcessGroup]

    /// Celé číslo pro zobrazení (nezměněný text nezneplatní pohled).
    var cpuPercentRounded: Int? { cpuPercent.map { Int($0.rounded()) } }
    /// Názvy nejvytíženějších skupin pro zobrazení.
    var topNames: [String] { topGroups.map(\.name) }
}

/// Zjišťuje, jestli sledované „AI“ procesy pracují: sečte přírůstek času CPU všech procesů,
/// které vyhoví `ProcessMatcher`, a porovná ho s prahem. Samotná existence procesu prací není
/// (aplikace Claude běží pořád).
///
/// Čte přes libproc (`proc_listallpids`, `proc_name`, `proc_pidpath`, `proc_pid_rusage`), nic nespouští.
/// Kadenci určuje volající (počítá se s 15–20 s); mezi vzorky nic neběží.
///
/// Omezení: proces, který mezi dvěma vzorky vznikl i skončil, se nezapočítá (jeho rodič, který vzoru
/// vyhovuje, bývá vidět). Síťový provoz se záměrně nesleduje.
actor ActivityWatcher {
    static let thresholdRange: ClosedRange<Double> = 1...20
    static let defaultThreshold: Double = 3
    static let topGroupLimit = 5

    private struct Usage {
        /// Čas startu procesu v jednotkách `mach_absolute_time`; odliší znovupoužité PID.
        var start: UInt64
        /// Uživatelský + systémový čas CPU v jednotkách `mach_absolute_time`.
        var cpu: UInt64
    }

    /// Zapamatované rozhodnutí o jednom PID. Platí, dokud se nezmění čas startu (znovupoužité PID)
    /// ani krátký název procesu (ten se mění při exec, čas startu ne).
    private struct Decision {
        var startSec: UInt64
        var startUsec: UInt64
        var comm: (UInt64, UInt64)
        /// Název pro zobrazení; `nil` = proces vzorům nevyhovuje.
        var name: String?
    }

    private var matcher: ProcessMatcher
    private var threshold: Double
    private let ownPID = getpid()

    private var previous: [pid_t: Usage] = [:]
    private var previousTicks: UInt64?
    /// Cesta a název procesu se zjišťují jen u PID, která jsou nová nebo se změnila; u ostatních
    /// stačí jedno levné volání na vzorek.
    private var decisions: [pid_t: Decision] = [:]

    private var pids: [pid_t] = []
    private var pathBuffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
    private var nameBuffer = [CChar](repeating: 0, count: 256)

    init(patterns: [String] = ProcessMatcher.defaultPatterns, thresholdPercent: Double = ActivityWatcher.defaultThreshold) {
        self.matcher = ProcessMatcher(patterns: patterns)
        self.threshold = Self.clamp(thresholdPercent)
    }

    /// Změna nastavení. Změna vzorů zahodí výchozí stav (další vzorek vrátí `cpuPercent == nil`).
    func configure(patterns: [String], thresholdPercent: Double) {
        let newMatcher = ProcessMatcher(patterns: patterns)
        if newMatcher != matcher {
            matcher = newMatcher
            reset()
        }
        threshold = Self.clamp(thresholdPercent)
    }

    /// Zahodí výchozí stav. Volat při vypnutí sledování, aby první vzorek po dalším zapnutí
    /// nebyl průměr za celou přestávku.
    func reset() {
        previous.removeAll(keepingCapacity: true)
        previousTicks = nil
        decisions.removeAll(keepingCapacity: true)
    }

    /// Jeden vzorek. `nil` jen když nejde získat seznam procesů.
    func sample() -> ActivitySample? {
        let nowTicks = mach_absolute_time()
        let uptime = ActivityClock.uptime()
        guard listPIDs() else {
            reset()
            return nil
        }

        let elapsedTicks = previousTicks.flatMap { nowTicks > $0 ? nowTicks - $0 : nil }
        let hasBaseline = elapsedTicks != nil

        var current: [pid_t: Usage] = [:]
        current.reserveCapacity(max(previous.count, 16))
        var nextDecisions: [pid_t: Decision] = [:]
        nextDecisions.reserveCapacity(max(decisions.count, 64))
        var groups: [String: (count: Int, cpu: UInt64)] = [:]
        var matched = 0
        var unreadable = 0
        var totalDelta: UInt64 = 0

        for pid in pids where pid > 0 && pid != ownPID {
            let decided: String?
            let cached = decisions[pid]
            if let identity = readIdentity(of: pid, preferShort: cached?.startSec == Self.shortIdentityMark) {
                if let cached, cached.startSec == identity.startSec,
                   cached.startUsec == identity.startUsec, cached.comm == identity.comm {
                    decided = cached.name
                } else {
                    decided = matchingName(of: pid)
                }
                nextDecisions[pid] = Decision(startSec: identity.startSec, startUsec: identity.startUsec,
                                              comm: identity.comm, name: decided)
            } else {
                // Bez údajů k ověření se nic nepamatuje.
                decided = matchingName(of: pid)
            }
            guard let name = decided else { continue }
            matched += 1
            var delta: UInt64 = 0
            if let usage = readUsage(of: pid) {
                current[pid] = usage
                if let before = previous[pid], before.start == usage.start {
                    delta = usage.cpu >= before.cpu ? usage.cpu - before.cpu : 0
                } else if let previousTicks, usage.start >= previousTicks {
                    // Proces vznikl až po předchozím vzorku: všechen jeho čas spadá do tohoto intervalu.
                    delta = usage.cpu
                }
                // Jinak je to starší proces viděný poprvé (např. po exec): bez výchozího stavu nelze nic tvrdit.
            } else {
                unreadable += 1
            }
            totalDelta &+= delta
            groups[name, default: (0, 0)].count += 1
            groups[name, default: (0, 0)].cpu &+= delta
        }

        previous = current
        previousTicks = nowTicks
        decisions = nextDecisions   // zaniklá PID vypadnou

        // Poměr dvou hodnot ve stejných jednotkách, takže převod přes mach_timebase_info není potřeba.
        func percent(_ delta: UInt64) -> Double? {
            guard let elapsedTicks else { return nil }
            return Double(delta) / Double(elapsedTicks) * 100
        }

        let cpuPercent = percent(totalDelta)
        let top = groups
            .sorted { lhs, rhs in
                if hasBaseline, lhs.value.cpu != rhs.value.cpu { return lhs.value.cpu > rhs.value.cpu }
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.key < rhs.key
            }
            .prefix(Self.topGroupLimit)
            .map { ActivityProcessGroup(name: $0.key, count: $0.value.count, cpuPercent: percent($0.value.cpu)) }

        return ActivitySample(uptime: uptime,
                              matchedCount: matched,
                              unreadableCount: unreadable,
                              cpuPercent: cpuPercent,
                              thresholdPercent: threshold,
                              isWorking: cpuPercent.map { $0 >= threshold },
                              topGroups: top)
    }

    // MARK: - libproc

    private func listPIDs() -> Bool {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return false }
        // Rezerva pro procesy, které vzniknou mezi oběma voláními.
        let capacity = Int(expected) + 64
        if pids.count < capacity {
            pids = [pid_t](repeating: 0, count: capacity)
        }
        let size = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let written = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, size) }
        guard written > 0 else { return false }
        // Zbytek pole vynulovat; nulové PID smyčka přeskočí.
        let count = min(Int(written), pids.count)
        if count < pids.count {
            for index in count..<pids.count { pids[index] = 0 }
        }
        return true
    }

    /// Název pro zobrazení, pokud proces vyhovuje vzorům; jinak `nil` (i když už proces neexistuje).
    private func matchingName(of pid: pid_t) -> String? {
        var executable: String?
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            executable = Self.lastPathComponent(pathBuffer, length: Int(pathLength))
        }
        var processName: String?
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLength > 0 {
            processName = Self.string(nameBuffer, from: 0, to: Int(nameLength))
        }
        guard matcher.matches(executable, processName) else { return nil }
        // Název ze souboru není zkrácený jako `proc_name`, proto má přednost.
        if let executable, !executable.isEmpty { return executable }
        return processName
    }

    private typealias Identity = (startSec: UInt64, startUsec: UInt64, comm: (UInt64, UInt64))

    /// Čas startu a krátký název procesu jedním levným voláním. Cizí procesy (root) plný údaj
    /// nevydají; u nich stačí zkrácená podoba bez času startu, doplněná o rodiče a vlastníka.
    /// `preferShort`: minule plný údaj nešel, zkusit rovnou zkrácený.
    private func readIdentity(of pid: pid_t, preferShort: Bool) -> Identity? {
        if preferShort, let identity = readShortIdentity(of: pid) { return identity }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            let comm = withUnsafeBytes(of: &info.pbi_comm) { bytes in
                (bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                 bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            }
            return (info.pbi_start_tvsec, info.pbi_start_tvusec, comm)
        }
        return preferShort ? nil : readShortIdentity(of: pid)
    }

    private func readShortIdentity(of pid: pid_t) -> Identity? {
        var short = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size else { return nil }
        let comm = withUnsafeBytes(of: &short.pbsi_comm) { bytes in
            (bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
             bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        // Skutečný čas startu v sekundách nikdy nedosáhne UInt64.max, takže se obě podoby nespletou.
        return (Self.shortIdentityMark, UInt64(short.pbsi_ppid) << 32 | UInt64(short.pbsi_uid), comm)
    }

    private static let shortIdentityMark = UInt64.max

    private func readUsage(of pid: pid_t) -> Usage? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return Usage(start: info.ri_proc_start_abstime, cpu: info.ri_user_time &+ info.ri_system_time)
    }

    private static func lastPathComponent(_ buffer: [CChar], length: Int) -> String? {
        let end = min(length, buffer.count)
        var start = 0
        for index in stride(from: end - 1, through: 0, by: -1) where buffer[index] == 0x2F {
            start = index + 1
            break
        }
        return string(buffer, from: start, to: end)
    }

    private static func string(_ buffer: [CChar], from start: Int, to end: Int) -> String? {
        guard start < end, end <= buffer.count else { return nil }
        // Neplatné UTF-8 se nahradí zástupným znakem, nikdy nespadne.
        return String(decoding: buffer[start..<end].lazy.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultThreshold }
        return min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
    }
}
