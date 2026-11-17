import Foundation
import IOKit.ps

/// Stav napájení. Chybějící údaj je `nil`.
struct PowerReading: Sendable, Equatable {
    /// Má Mac vnitřní baterii?
    var hasBattery: Bool
    /// Nabití 0–100; `nil` bez baterie nebo když ho systém nevydá.
    var batteryPercent: Int?
    /// Běží na baterii (vybíjí se)?
    var isOnBattery: Bool

    static let unknown = PowerReading(hasBattery: false, batteryPercent: nil, isOnBattery: false)
}

/// Proč má aplikace režim B sama vypnout.
enum SafetyStopReason: Sendable, Equatable {
    case lowBattery(percent: Int, threshold: Int)
    case thermal(ProcessInfo.ThermalState)

    /// Česká část věty za dvojtečkou („baterie pod 20 %").
    var explanation: String {
        switch self {
        case .lowBattery(_, let threshold):
            String(localized: "baterie pod \(threshold)\u{00A0}%")
        case .thermal:
            String(localized: "Mac se příliš zahřívá")
        }
    }
}

/// Čte baterii a tepelný stav a vyhodnocuje bezpečnostní prahy režimu B.
enum SafetyMonitor {
    /// Aktuální stav napájení (synchronně; rychlé čtení z IOKit).
    static func readPower() -> PowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let present = info[kIOPSIsPresentKey] as? Bool, !present { continue }

            var percent: Int?
            if let current = info[kIOPSCurrentCapacityKey] as? Int,
               let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            }
            let onBattery = info[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return PowerReading(hasBattery: true, batteryPercent: percent, isOnBattery: onBattery)
        }
        return .unknown
    }

    /// Totéž mimo hlavní vlákno.
    @concurrent
    static func currentPower() async -> PowerReading {
        readPower()
    }

    static var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// Vrátí důvod k vypnutí, když je překročen některý práh; jinak `nil`.
    /// Baterie se počítá jen při běhu na baterii; bez baterie nikdy. Práh 0 = nehlídat.
    static func evaluate(power: PowerReading,
                         thermalState: ProcessInfo.ThermalState,
                         batteryThresholdPercent: Int,
                         thermalLimit: ThermalLimit) -> SafetyStopReason? {
        if batteryThresholdPercent > 0, power.hasBattery, power.isOnBattery,
           let percent = power.batteryPercent, percent < batteryThresholdPercent {
            return .lowBattery(percent: percent, threshold: batteryThresholdPercent)
        }
        if thermalLimit > 0, thermalState.rawValue >= thermalLimit {
            return .thermal(thermalState)
        }
        return nil
    }
}
