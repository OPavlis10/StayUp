import Foundation
import IOKit
import IOKit.ps

/// Příkon počítače a výdrž baterie z IORegistry (`AppleSmartBattery`) a `IOPSGetTimeRemainingEstimate`.
///
/// Příkon: na adaptéru `PowerTelemetryData.SystemLoad` (mW, spotřeba celého počítače; systém ho
/// obnovuje jen zhruba jednou za půl minuty až minutu). Na baterii vybíjecí proud × napětí
/// (`Amperage` × `Voltage`), což je tatáž veličina změřená čerstvěji; telemetrie je pak záloha.
/// Určeno pro otevřený panel, zhruba každých 10 s.
struct PowerDrawSampler {
    /// Časová konstanta vyhlazení odběru pro vlastní odhad výdrže.
    private let smoothingTime: TimeInterval
    private var smoothedDrawMilliamps: Double?
    private var smoothedSince: Date?
    private var lastSample: Date?

    init(smoothingTime: TimeInterval = 60) {
        self.smoothingTime = smoothingTime
    }

    /// Zahodí vyhlazený odběr (např. po delší pauze).
    mutating func reset() {
        smoothedDrawMilliamps = nil
        smoothedSince = nil
        lastSample = nil
    }

    /// `nil` na Macu bez baterie nebo když registr neodpoví.
    mutating func sample(now: Date = Date()) -> PowerDrawMetrics? {
        guard let raw = Self.readBattery() else {
            reset()
            return nil
        }

        let isOnAC = raw.externalConnected ?? false
        // Proud je se znaménkem: záporný = vybíjení, kladný = nabíjení.
        let milliamps = raw.amperage ?? raw.instantAmperage
        var batteryWatts: Double?
        if let milliamps, let millivolts = raw.voltage, millivolts > 0 {
            // U nulového proudu nevracet -0,0.
            batteryWatts = milliamps == 0 ? 0 : -Double(milliamps) * Double(millivolts) / 1_000_000
        }

        var systemWatts: Double?
        var systemSource: SystemPowerSource?
        if !isOnAC, let batteryWatts, batteryWatts > 0 {
            systemWatts = batteryWatts
            systemSource = .batteryDischarge
        } else if let load = raw.telemetrySystemLoad, load > 0 {
            systemWatts = Double(load) / 1000
            systemSource = .telemetrySystemLoad
        } else if let batteryWatts, batteryWatts > 0 {
            systemWatts = batteryWatts
            systemSource = .batteryDischarge
        }

        var adapterInputWatts: Double?
        if isOnAC, let powerIn = raw.telemetrySystemPowerIn, powerIn > 0 {
            adapterInputWatts = Double(powerIn) / 1000
        }

        // Vyhlazený vybíjecí proud pro vlastní odhad.
        if !isOnAC, let milliamps, milliamps < 0 {
            let draw = Double(-milliamps)
            if let previous = smoothedDrawMilliamps, let last = lastSample {
                let dt = max(now.timeIntervalSince(last), 0)
                // Po dlouhé pauze začít znovu, starý průměr už nic neříká.
                if dt > smoothingTime * 5 {
                    smoothedDrawMilliamps = draw
                    smoothedSince = now
                } else {
                    let alpha = 1 - exp(-dt / smoothingTime)
                    smoothedDrawMilliamps = previous + (draw - previous) * alpha
                }
            } else {
                smoothedDrawMilliamps = draw
                smoothedSince = now
            }
        } else {
            smoothedDrawMilliamps = nil
            smoothedSince = nil
        }
        lastSample = now

        let timeRemaining: BatteryTimeRemaining
        let systemEstimate = IOPSGetTimeRemainingEstimate()
        if isOnAC || systemEstimate == kIOPSTimeRemainingUnlimited {
            timeRemaining = .unlimited
        } else if systemEstimate >= 0 {
            timeRemaining = .minutes(Int((systemEstimate / 60).rounded()), source: .system)
        } else if let draw = smoothedDrawMilliamps, draw >= 20, let capacity = raw.rawCurrentCapacity, capacity > 0 {
            let minutes = Double(capacity) / draw * 60
            // Přes dva dny je odhad z okamžitého odběru k ničemu.
            timeRemaining = minutes <= 48 * 60 ? .minutes(Int(minutes.rounded()), source: .estimated) : .unknown
        } else {
            timeRemaining = .unknown
        }

        let isCharging = raw.isCharging ?? false
        var minutesToFull: Int?
        if isCharging, let toFull = raw.avgTimeToFull, toFull > 0, toFull < 65535 {
            minutesToFull = toFull
        }

        return PowerDrawMetrics(systemWatts: systemWatts,
                                systemSource: systemSource,
                                batteryWatts: batteryWatts,
                                adapterInputWatts: adapterInputWatts,
                                adapterRatedWatts: isOnAC ? raw.adapterWatts : nil,
                                isOnAC: isOnAC,
                                isCharging: isCharging,
                                isFullyCharged: raw.fullyCharged ?? false,
                                chargePercent: raw.chargePercent,
                                remainingCapacitymAh: raw.rawCurrentCapacity,
                                timeRemaining: timeRemaining,
                                minutesToFull: minutesToFull)
    }

    // MARK: - IORegistry

    private struct RawBattery {
        var amperage: Int?
        var instantAmperage: Int?
        var voltage: Int?
        var externalConnected: Bool?
        var isCharging: Bool?
        var fullyCharged: Bool?
        var chargePercent: Int?
        var rawCurrentCapacity: Int?
        var avgTimeToFull: Int?
        var adapterWatts: Int?
        var telemetrySystemLoad: Int?
        var telemetrySystemPowerIn: Int?
    }

    private static func readBattery() -> RawBattery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // Záporná čísla registr ukládá jako 64bitová bez znaménka; int64Value je vrátí správně.
        func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
            return Int(number.int64Value)
        }
        func boolean(_ value: Any?) -> Bool? {
            (value as? NSNumber)?.boolValue
        }

        if let installed = boolean(property("BatteryInstalled")), !installed { return nil }

        // Každé čtení je volání do jádra, proto se čte jen to, co je v daném stavu potřeba.
        var raw = RawBattery()
        raw.amperage = integer(property("Amperage"))
        if raw.amperage == nil { raw.instantAmperage = integer(property("InstantAmperage")) }
        raw.voltage = integer(property("Voltage"))
        raw.externalConnected = boolean(property("ExternalConnected"))
        raw.isCharging = boolean(property("IsCharging"))
        raw.fullyCharged = boolean(property("FullyCharged"))
        // Na Apple Silicon je CurrentCapacity / MaxCapacity v procentech (MaxCapacity = 100),
        // na Intelu v mAh; podíl funguje pro oboje.
        if let current = integer(property("CurrentCapacity")), let maximum = integer(property("MaxCapacity")), maximum > 0 {
            raw.chargePercent = min(max(Int((Double(current) / Double(maximum) * 100).rounded()), 0), 100)
        }

        let onAC = raw.externalConnected ?? false
        let discharging = (raw.amperage ?? raw.instantAmperage ?? 0) < 0
        if onAC {
            if let adapter = property("AdapterDetails") as? [String: Any], let watts = integer(adapter["Watts"]), watts > 0 {
                raw.adapterWatts = watts
            }
            if raw.isCharging == true { raw.avgTimeToFull = integer(property("AvgTimeToFull")) }
        } else {
            // Kapacita v mAh (pro vlastní odhad výdrže) je na Apple Silicon ve slovníku BatteryData,
            // na starších Macích přímo v položce.
            if let data = property("BatteryData") as? [String: Any] {
                raw.rawCurrentCapacity = integer(data["AppleRawCurrentCapacity"]) ?? integer(data["RemainingCapacity"])
            }
            if raw.rawCurrentCapacity == nil { raw.rawCurrentCapacity = integer(property("AppleRawCurrentCapacity")) }
        }
        // Telemetrie je potřeba na adaptéru; na baterii jen když chybí vybíjecí proud.
        if onAC || !discharging, let telemetry = property("PowerTelemetryData") as? [String: Any] {
            raw.telemetrySystemLoad = integer(telemetry["SystemLoad"])
            raw.telemetrySystemPowerIn = integer(telemetry["SystemPowerIn"])
        }
        // Bez napětí i proudu to není použitelná baterie.
        guard raw.voltage != nil || raw.amperage != nil || raw.chargePercent != nil else { return nil }
        return raw
    }
}
