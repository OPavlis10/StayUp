import Foundation

// Datové typy modulu Energie („Kdo žere energii" a „Příkon a výdrž"). Vše je Sendable, vzniká
// v actoru EnergyCollector a čte se na hlavním vlákně. Chybějící údaj je vždy `nil`.

/// Jedna aplikace (nebo samostatný proces) v žebříčku. Pomocné procesy uvnitř balíčku `.app`
/// jsou sečtené pod svou aplikací.
struct ProcessEnergyEntry: Sendable, Equatable, Identifiable {
    /// Stabilní klíč skupiny: cesta k balíčku `.app`, jinak cesta ke spustitelnému souboru.
    var id: String
    /// Název pro zobrazení (lokalizovaný název aplikace, jinak název spustitelného souboru).
    var name: String
    /// Využití CPU v procentech jednoho jádra (může být přes 100), průměr za poslední měřený úsek
    /// (u činných procesů od minulého vzorku, u nečinných až za čtyři vzorky).
    var cpuPercent: Double
    /// Průměrný příkon ve wattech podle počítadla energie v jádře (jen CPU, bez displeje a GPU);
    /// `nil`, když systém energii neúčtuje.
    var watts: Double?
    /// Kolik procesů je ve skupině sečteno.
    var processCount: Int
}

enum ProcessRanking: Sendable, Equatable {
    case cpu
    case power
}

struct TopProcessesSnapshot: Sendable, Equatable {
    /// Nejvýš `limit` položek, seřazeno sestupně podle `ranking`.
    var entries: [ProcessEnergyEntry]
    var ranking: ProcessRanking
    /// Součet přes všechny čitelné procesy (ne jen přes zobrazené).
    var totalCPUPercent: Double
    var totalWatts: Double?
    /// Procesy, které šlo přečíst (patří přihlášenému uživateli).
    var readableProcessCount: Int
    /// Všechny procesy v systému (odhad jádra, může být o pár vyšší než skutečnost).
    var totalProcessCount: Int
    /// Doba od předchozího vzorku v sekundách.
    var interval: TimeInterval

    /// Procesy jiných uživatelů a systému (root) bez oprávnění přečíst nejdou; v UI to přiznat.
    var isLimitedToCurrentUser: Bool { readableProcessCount < totalProcessCount }
}

/// Odkud je údaj o příkonu celého počítače.
enum SystemPowerSource: String, Sendable, Equatable {
    /// `PowerTelemetryData.SystemLoad` (mW) z AppleSmartBattery. Systém ho obnovuje jen zhruba
    /// jednou za půl minuty až minutu.
    case telemetrySystemLoad
    /// Vybíjecí proud × napětí baterie (`Amperage` × `Voltage`); při běhu na baterii je to
    /// spotřeba celého počítače.
    case batteryDischarge
}

enum BatteryTimeSource: Sendable, Equatable {
    /// `IOPSGetTimeRemainingEstimate`.
    case system
    /// Vlastní odhad: zbývající kapacita / vyhlazený odběr.
    case estimated
}

enum BatteryTimeRemaining: Sendable, Equatable {
    case minutes(Int, source: BatteryTimeSource)
    /// Napájení ze sítě.
    case unlimited
    /// Systém ještě počítá a vlastní odhad zatím není z čeho udělat.
    case unknown
}

/// Příkon a baterie. Stolní Mac bez baterie nevrací nic (`PowerDrawSampler.sample()` dá `nil`).
struct PowerDrawMetrics: Sendable, Equatable {
    /// Příkon celého počítače ve wattech; `nil`, když ho nelze zjistit (např. ze sítě bez telemetrie).
    var systemWatts: Double?
    var systemSource: SystemPowerSource?
    /// Výkon baterie ve wattech: kladný = vybíjí se, záporný = nabíjí se, 0 = baterie se nepoužívá.
    var batteryWatts: Double?
    /// Co právě dodává adaptér (`PowerTelemetryData.SystemPowerIn`); `nil` na baterii nebo bez telemetrie.
    var adapterInputWatts: Double?
    /// Jmenovitý výkon připojeného adaptéru (`AdapterDetails.Watts`).
    var adapterRatedWatts: Int?
    var isOnAC: Bool
    var isCharging: Bool
    var isFullyCharged: Bool
    /// Nabití v procentech tak, jak ho ukazuje systém.
    var chargePercent: Int?
    /// Zbývající kapacita v mAh (`AppleRawCurrentCapacity`); čte se jen při běhu na baterii.
    var remainingCapacitymAh: Int?
    var timeRemaining: BatteryTimeRemaining
    /// Minuty do plného nabití (`AvgTimeToFull`); `nil`, když se nenabíjí nebo systém neví.
    var minutesToFull: Int?
}

/// Řádky žebříčku tak, jak jsou vidět: hotové texty. Porovnává se tohle, ne surová čísla,
/// aby nezměněný text nepřekresloval zobrazení.
struct TopProcessesDisplay: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        /// Např. „12 %" nebo „3,4 %".
        var cpuText: String
        /// Např. „1,2 W"; `nil`, když příkon není znám.
        var powerText: String?
    }
    var rows: [Row]
    var ranking: ProcessRanking
    var isLimitedToCurrentUser: Bool

    init(_ snapshot: TopProcessesSnapshot) {
        rows = snapshot.entries.map { entry in
            Row(id: entry.id,
                name: entry.name,
                cpuText: EnergyFormatter.cpuPercent(entry.cpuPercent),
                powerText: entry.watts.map { EnergyFormatter.processWatts($0) })
        }
        ranking = snapshot.ranking
        isLimitedToCurrentUser = snapshot.isLimitedToCurrentUser
    }
}

/// Příkon a výdrž tak, jak jsou vidět. Slovní popisky („Zbývá", „Nabíjí se"…) patří do UI
/// a do String Catalogu; tady jsou jen čísla s jednotkami.
struct PowerDrawDisplay: Sendable, Equatable {
    /// Příkon počítače, např. „8,4 W".
    var systemText: String?
    var systemSource: SystemPowerSource?
    /// Výkon baterie bez znaménka, např. „12,0 W"; směr určuje `isCharging` / `isOnAC`.
    var batteryText: String?
    /// Např. „23,5 W".
    var adapterInputText: String?
    /// Např. „61 W".
    var adapterRatedText: String?
    var isOnAC: Bool
    var isCharging: Bool
    var isFullyCharged: Bool
    /// Např. „90 %".
    var chargeText: String?
    /// Např. „3 h 20 min"; `nil` pro `.unlimited` i `.unknown` (rozliší `timeRemaining`).
    var remainingText: String?
    /// Stav výdrže se zaokrouhlenými minutami (stejnými jako v `remainingText`).
    var timeRemaining: BatteryTimeRemaining
    /// Např. „1 h 5 min" do plného nabití.
    var toFullText: String?

    init(_ metrics: PowerDrawMetrics) {
        systemText = metrics.systemWatts.map { EnergyFormatter.watts($0) }
        systemSource = metrics.systemSource
        batteryText = metrics.batteryWatts.flatMap { abs($0) >= 0.05 ? EnergyFormatter.watts(abs($0)) : nil }
        adapterInputText = metrics.adapterInputWatts.map { EnergyFormatter.watts($0) }
        adapterRatedText = metrics.adapterRatedWatts.map { EnergyFormatter.watts(Double($0), fractionDigits: 0) }
        isOnAC = metrics.isOnAC
        isCharging = metrics.isCharging
        isFullyCharged = metrics.isFullyCharged
        chargeText = metrics.chargePercent.map { MetricsFormatter.percent(Double($0) / 100) }
        switch metrics.timeRemaining {
        case .minutes(let minutes, let source):
            // Vlastní odhad se hýbe s každým vzorkem; krok 5 minut ho uklidní.
            let shown = source == .estimated && minutes >= 30 ? Int((Double(minutes) / 5).rounded()) * 5 : minutes
            timeRemaining = .minutes(shown, source: source)
            remainingText = EnergyFormatter.duration(minutes: shown)
        case .unlimited, .unknown:
            timeRemaining = metrics.timeRemaining
            remainingText = nil
        }
        toFullText = metrics.minutesToFull.map { EnergyFormatter.duration(minutes: $0) }
    }
}
