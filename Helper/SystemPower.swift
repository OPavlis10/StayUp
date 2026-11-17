import Foundation
import IOKit
import IOKit.ps

/// Skutečné přepínání přes `/usr/bin/pmset`. Argumenty jsou pevné; nic z klienta se sem nedostane.
/// Smí jen dvě nastavení: `disablesleep` a `lowpowermode`.
struct PmsetPowerSetting: PowerSettingApplying {
    private static let pmsetPath = "/usr/bin/pmset"
    private static let timeout: TimeInterval = 15

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let arguments = disabled ? ["-a", "disablesleep", "1"] : ["-a", "disablesleep", "0"]
        return Self.run(arguments, captureOutput: false)?.status == 0
    }

    func readSleepDisabled() -> Bool? {
        Self.readFromRegistry() ?? Self.readFromPmset()
    }

    func readLowPowerMode() -> LowPowerReading {
        guard let result = Self.run(["-g"], captureOutput: true), result.status == 0 else { return .unreadable }
        return PmsetOutput.lowPowerMode(inLiveSettings: result.output)
    }

    func readLowPowerProfiles() -> LowPowerState? {
        guard let result = Self.run(["-g", "custom"], captureOutput: true), result.status == 0 else { return nil }
        return PmsetOutput.lowPowerProfiles(inCustomSettings: result.output)
    }

    func setLowPowerMode(_ enabled: Bool, profile: PowerProfile?) -> Bool {
        // Přepínač zdroje je jedna ze čtyř pevných hodnot, hodnota je "1" nebo "0".
        let arguments = [profile?.pmsetFlag ?? "-a", "lowpowermode", enabled ? "1" : "0"]
        return Self.run(arguments, captureOutput: false)?.status == 0
    }
    /// Veřejná vlastnost `SleepDisabled` na IOPMrootDomain – bez spouštění procesu.
    private static func readFromRegistry() -> Bool? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool
    }

    /// Záloha: řádek „SleepDisabled  1" z výstupu `pmset -g`.
    private static func readFromPmset() -> Bool? {
        guard let result = run(["-g"], captureOutput: true), result.status == 0 else { return nil }
        return PmsetOutput.sleepDisabled(inLiveSettings: result.output)
    }

    private static func run(_ arguments: [String], captureOutput: Bool) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = captureOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            helperLog.error("pmset nelze spustit: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            helperLog.error("pmset neodpovídá, ukončuji ho")
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                done.wait()
            }
            return nil
        }
        var output = ""
        if let pipe {
            // Výstup `pmset -g` i `pmset -g custom` je malý (vejde se do bufferu roury), čtení po skončení neblokuje.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(decoding: data, as: UTF8.self)
        }
        return (process.terminationStatus, output)
    }
}

/// Čtení výstupu `pmset -g` a `pmset -g custom`. Čisté funkce, aby šly ověřit bez spouštění pmset.
enum PmsetOutput {
    /// Řádek „SleepDisabled  1" z `pmset -g`.
    static func sleepDisabled(inLiveSettings output: String) -> Bool? {
        guard let value = firstValue(of: "SleepDisabled", in: output[...]) else { return nil }
        return value == "1"
    }

    /// Řádek „lowpowermode  0" z `pmset -g` (právě platné nastavení). Chybějící řádek znamená,
    /// že Mac úsporný režim nemá; jiná hodnota než 0 nebo 1 se nehádá.
    static func lowPowerMode(inLiveSettings output: String) -> LowPowerReading {
        guard let value = firstValue(of: "lowpowermode", in: output[...]) else { return .unsupported }
        return flag(value).map(LowPowerReading.value) ?? .unreadable
    }

    /// Hodnoty `lowpowermode` po zdrojích napájení z `pmset -g custom`. Výstup má oddíly
    /// „Battery Power:", „AC Power:" a případně „UPS Power:"; oddíl, který chybí nebo řádek nemá,
    /// zůstane nil. Vrací nil, když hodnotu nemá žádný oddíl nebo některá není 0 ani 1.
    static func lowPowerProfiles(inCustomSettings output: String) -> LowPowerState? {
        var state = LowPowerState()
        var current: PowerProfile?
        for line in output.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.count == line.count, line.hasSuffix(":") {
                // Záhlaví oddílu (neodsazené). Neznámý oddíl se přeskočí celý.
                current = PowerProfile.allCases.first { line == $0.pmsetSectionTitle + ":" }
                continue
            }
            guard let profile = current, let value = firstValue(of: "lowpowermode", in: line) else { continue }
            guard let enabled = flag(value) else { return nil }
            state[profile] = enabled
        }
        return state.isEmpty ? nil : state
    }

    private static func flag(_ token: Substring) -> Bool? {
        switch token {
        case "1": true
        case "0": false
        default: nil
        }
    }

    /// Druhé slovo prvního řádku, jehož první slovo je `key`.
    private static func firstValue(of key: String, in text: Substring) -> Substring? {
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == key { return parts[1] }
        }
        return nil
    }
}

/// Baterie přes IOKit Power Sources, teplota přes ProcessInfo.
struct SystemEnvironment: EnvironmentProbing {
    func powerSource() -> PowerSourceSnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0,
                  let state = info[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return PowerSourceSnapshot(onBattery: state == kIOPSBatteryPowerValue,
                                       percent: min(100, max(0, percent)))
        }
        return nil
    }

    func thermalLevel() -> Int {
        ProcessInfo.processInfo.thermalState.rawValue
    }
}
