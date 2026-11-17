import Foundation
import Observation
import ServiceManagement

/// Stav přepínačů zapamatovaný pro obnovení po dalším spuštění.
struct RememberedSwitches: Sendable, Equatable {
    var keepAwake: Bool
    var neverSleep: Bool
    /// Úsporný režim (na časovači nezávisí).
    var lowPower: Bool
    /// Konec společného časovače; `nil` = do vypnutí.
    var expiresAt: Date?
}

/// Uživatelské nastavení aplikace uložené v UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let batteryThresholdRange: ClosedRange<Int> = 5...80
    static let thermalLimitRange: ClosedRange<Int> = 0...3
    static let aiCPUThresholdRange: ClosedRange<Int> =
        Int(ActivityWatcher.thresholdRange.lowerBound)...Int(ActivityWatcher.thresholdRange.upperBound)

    private enum Key {
        static let batteryThreshold = "batteryThresholdPercent"
        static let thermalLimit = "thermalLimit"
        static let restoreAfterRestart = "restoreSwitchesAfterRestart"
        static let defaultDuration = "defaultDuration"
        static let lastKeepAwake = "lastKeepAwake"
        static let lastNeverSleep = "lastNeverSleep"
        static let lastLowPower = "lastLowPower"
        static let autoOffWhenAIIdle = "autoOffWhenAIIdle"
        static let aiProcessPatterns = "aiProcessPatterns"
        static let aiCPUThreshold = "aiCPUThresholdPercent"
        static let aiIdleMinutes = "aiIdleMinutes"
        static let networkWatchEnabled = "networkWatchEnabled"
        static let networkEndAfterEnabled = "networkEndAfterEnabled"
        static let networkEndAfterMinutes = "networkEndAfterMinutes"
        static let lastExpiresAt = "lastExpiresAt"
        static let lastBootTime = "lastStateBootTime"
    }

    /// Pod kolik procent baterie se režim B sám vypne (5–80).
    var batteryThresholdPercent: Int {
        didSet {
            let clamped = Self.clamp(batteryThresholdPercent, to: Self.batteryThresholdRange)
            if clamped != batteryThresholdPercent { batteryThresholdPercent = clamped; return }
            defaults.set(clamped, forKey: Key.batteryThreshold)
        }
    }

    /// Od jakého tepelného stavu se režim B vypne (0 = nehlídat, 1 fair, 2 serious, 3 critical).
    var thermalLimit: ThermalLimit {
        didSet {
            let clamped = Self.clamp(thermalLimit, to: Self.thermalLimitRange)
            if clamped != thermalLimit { thermalLimit = clamped; return }
            defaults.set(clamped, forKey: Key.thermalLimit)
        }
    }

    /// Obnovit přepínače i po restartu Macu (jinak jen po novém spuštění aplikace v témže běhu systému).
    var restoreSwitchesAfterRestart: Bool {
        didSet { defaults.set(restoreSwitchesAfterRestart, forKey: Key.restoreAfterRestart) }
    }

    /// Výchozí doba, na kterou se přepínače zapínají.
    var defaultDuration: AwakeDuration {
        didSet { defaults.set(defaultDuration.rawValue, forKey: Key.defaultDuration) }
    }

    // MARK: Bdění podle AI

    /// „Bdít, jen dokud AI pracuje": když sledované procesy dost dlouho nepracují, bdění se vypne.
    var autoOffWhenAIIdle: Bool {
        didSet { defaults.set(autoOffWhenAIIdle, forKey: Key.autoOffWhenAIIdle) }
    }

    /// Vzory názvů sledovaných procesů (vyčištěné, malými písmeny). Prázdný seznam se nahradí výchozím.
    var aiProcessPatterns: [String] {
        didSet {
            var cleaned = ProcessMatcher.normalize(aiProcessPatterns)
            if cleaned.isEmpty { cleaned = ProcessMatcher.defaultPatterns }
            if cleaned != aiProcessPatterns { aiProcessPatterns = cleaned; return }
            defaults.set(cleaned, forKey: Key.aiProcessPatterns)
        }
    }

    /// Od kolika procent jednoho jádra se sledované procesy berou jako pracující (1–20).
    var aiCPUThresholdPercent: Int {
        didSet {
            let clamped = Self.clamp(aiCPUThresholdPercent, to: Self.aiCPUThresholdRange)
            if clamped != aiCPUThresholdPercent { aiCPUThresholdPercent = clamped; return }
            defaults.set(clamped, forKey: Key.aiCPUThreshold)
        }
    }

    /// Po kolika minutách nečinnosti se bdění vypne (2–120).
    var aiIdleMinutes: Int {
        didSet {
            let clamped = Self.clamp(aiIdleMinutes, to: IdleTracker.minutesRange)
            if clamped != aiIdleMinutes { aiIdleMinutes = clamped; return }
            defaults.set(clamped, forKey: Key.aiIdleMinutes)
        }
    }

    // MARK: Hlídání sítě

    /// Oznámit, když Mac při zapnutém bdění ztratí připojení (a když se vrátí).
    var networkWatchEnabled: Bool {
        didSet { defaults.set(networkWatchEnabled, forKey: Key.networkWatchEnabled) }
    }

    /// Při delším výpadku připojení bdění ukončit.
    var networkEndAfterEnabled: Bool {
        didSet { defaults.set(networkEndAfterEnabled, forKey: Key.networkEndAfterEnabled) }
    }

    /// Po kolika minutách bez připojení se bdění ukončí (1–120).
    var networkEndAfterMinutes: Int {
        didSet {
            let clamped = Self.clamp(networkEndAfterMinutes, to: OutageTracker.endAfterMinutesRange)
            if clamped != networkEndAfterMinutes { networkEndAfterMinutes = clamped; return }
            defaults.set(clamped, forKey: Key.networkEndAfterMinutes)
        }
    }

    /// Spouštět po přihlášení. Zápis volá SMAppService.mainApp; při chybě se hodnota vrátí
    /// ke skutečnému stavu a chyba je v `launchAtLoginError`.
    var launchAtLogin: Bool = false {
        didSet {
            guard !syncingLaunchAtLogin, launchAtLogin != oldValue else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    /// Poslední chyba při změně „Spouštět po přihlášení" (česky), jinak `nil`.
    private(set) var launchAtLoginError: String?

    // Zapamatovaný stav přepínačů.
    private(set) var lastKeepAwake: Bool
    private(set) var lastNeverSleep: Bool
    private(set) var lastLowPower: Bool
    private(set) var lastExpiresAt: Date?
    /// Čas startu systému ve chvíli, kdy se stav ukládal.
    private(set) var lastSavedBootTime: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var syncingLaunchAtLogin = false
    @ObservationIgnored private var launchAtLoginGeneration = 0
    /// Pořadí poslední požadované změny (ne pouhého načtení), kvůli hlášení chyby.
    @ObservationIgnored private var launchAtLoginChangeGeneration = 0
    @ObservationIgnored private var launchAtLoginTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let battery = defaults.object(forKey: Key.batteryThreshold) as? Int ?? 20
        batteryThresholdPercent = Self.clamp(battery, to: Self.batteryThresholdRange)
        let thermal = defaults.object(forKey: Key.thermalLimit) as? Int ?? 2
        thermalLimit = Self.clamp(thermal, to: Self.thermalLimitRange)
        restoreSwitchesAfterRestart = defaults.bool(forKey: Key.restoreAfterRestart)
        autoOffWhenAIIdle = defaults.bool(forKey: Key.autoOffWhenAIIdle)
        let patterns = ProcessMatcher.normalize(defaults.stringArray(forKey: Key.aiProcessPatterns) ?? [])
        aiProcessPatterns = patterns.isEmpty ? ProcessMatcher.defaultPatterns : patterns
        let aiThreshold = defaults.object(forKey: Key.aiCPUThreshold) as? Int ?? Int(ActivityWatcher.defaultThreshold)
        aiCPUThresholdPercent = Self.clamp(aiThreshold, to: Self.aiCPUThresholdRange)
        let aiMinutes = defaults.object(forKey: Key.aiIdleMinutes) as? Int ?? IdleTracker.defaultMinutes
        aiIdleMinutes = Self.clamp(aiMinutes, to: IdleTracker.minutesRange)
        // Hlídání sítě je ve výchozím stavu zapnuté; ukončení bdění při výpadku vypnuté.
        networkWatchEnabled = defaults.object(forKey: Key.networkWatchEnabled) as? Bool ?? true
        networkEndAfterEnabled = defaults.bool(forKey: Key.networkEndAfterEnabled)
        let endMinutes = defaults.object(forKey: Key.networkEndAfterMinutes) as? Int ?? OutageTracker.defaultEndAfterMinutes
        networkEndAfterMinutes = Self.clamp(endMinutes, to: OutageTracker.endAfterMinutesRange)
        defaultDuration = defaults.string(forKey: Key.defaultDuration).flatMap(AwakeDuration.init(rawValue:)) ?? .untilOff
        lastKeepAwake = defaults.bool(forKey: Key.lastKeepAwake)
        lastNeverSleep = defaults.bool(forKey: Key.lastNeverSleep)
        lastLowPower = defaults.bool(forKey: Key.lastLowPower)
        lastExpiresAt = (defaults.object(forKey: Key.lastExpiresAt) as? Double).map(Date.init(timeIntervalSince1970:))
        lastSavedBootTime = (defaults.object(forKey: Key.lastBootTime) as? Double).map(Date.init(timeIntervalSince1970:))
        refreshLaunchAtLogin()
    }

    // MARK: - Spouštění po přihlášení

    /// Načte skutečný stav z SMAppService (mimo hlavní vlákno).
    func refreshLaunchAtLogin() {
        enqueueLaunchAtLogin(change: nil)
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        launchAtLoginError = nil
        enqueueLaunchAtLogin(change: on)
    }

    /// Změny i čtení stavu běží jedna po druhé v pořadí požadavků. Nejnovější požadavek tak
    /// doběhne poslední a čte stav až po všech dřívějších registracích, takže přepínač odpovídá
    /// skutečnosti i při rychlém přepínání.
    private func enqueueLaunchAtLogin(change: Bool?) {
        launchAtLoginGeneration += 1
        let generation = launchAtLoginGeneration
        if change != nil { launchAtLoginChangeGeneration = generation }
        let previous = launchAtLoginTask
        launchAtLoginTask = Task { [weak self] in
            await previous?.value
            let result: (enabled: Bool, error: String?)
            if let change {
                result = await Self.changeLoginItem(enable: change)
            } else {
                result = (await Self.loginItemEnabled(), nil)
            }
            guard let self else { return }
            // Chyba patří k poslední požadované změně; pozdější pouhé načtení stavu ji nezahodí.
            if change != nil, generation == self.launchAtLoginChangeGeneration {
                self.launchAtLoginError = result.error
            }
            guard generation == self.launchAtLoginGeneration else { return }
            self.setLaunchAtLoginSilently(result.enabled)
        }
    }

    private func setLaunchAtLoginSilently(_ value: Bool) {
        guard launchAtLogin != value else { return }
        syncingLaunchAtLogin = true
        launchAtLogin = value
        syncingLaunchAtLogin = false
    }

    @concurrent
    private nonisolated static func loginItemEnabled() async -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @concurrent
    private nonisolated static func changeLoginItem(enable: Bool) async -> (enabled: Bool, error: String?) {
        let service = SMAppService.mainApp
        var message: String?
        do {
            if enable {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try await service.unregister()
            }
        } catch {
            message = enable
                ? String(localized: "Spouštění po přihlášení se nepodařilo zapnout: \(error.localizedDescription)")
                : String(localized: "Spouštění po přihlášení se nepodařilo vypnout: \(error.localizedDescription)")
        }
        let status = service.status
        if message == nil, enable, status == .requiresApproval {
            message = String(localized: "Spouštění po přihlášení je potřeba povolit v Nastavení systému › Obecné › Položky přihlášení.")
        }
        return (status == .enabled, message)
    }

    // MARK: - Zapamatovaný stav přepínačů

    /// Uloží stav přepínačů spolu s časem startu systému.
    func rememberSwitches(keepAwake: Bool, neverSleep: Bool, lowPower: Bool, expiresAt: Date?) {
        lastKeepAwake = keepAwake
        lastNeverSleep = neverSleep
        lastLowPower = lowPower
        defaults.set(lowPower, forKey: Key.lastLowPower)
        lastExpiresAt = expiresAt
        lastSavedBootTime = Self.systemBootTime()
        defaults.set(keepAwake, forKey: Key.lastKeepAwake)
        defaults.set(neverSleep, forKey: Key.lastNeverSleep)
        if let expiresAt {
            defaults.set(expiresAt.timeIntervalSince1970, forKey: Key.lastExpiresAt)
        } else {
            defaults.removeObject(forKey: Key.lastExpiresAt)
        }
        if let boot = lastSavedBootTime {
            defaults.set(boot.timeIntervalSince1970, forKey: Key.lastBootTime)
        } else {
            defaults.removeObject(forKey: Key.lastBootTime)
        }
    }

    /// Co se má po spuštění obnovit; `nil` = nic.
    /// Stejný běh systému: obnoví se zapamatovaný stav. Po restartu Macu jen při `restoreSwitchesAfterRestart`.
    /// Když už uložený časovač vypršel, přepínače spánku se neobnoví; úsporný režim na časovači nezávisí.
    func switchesToRestore(now: Date = Date()) -> RememberedSwitches? {
        guard lastKeepAwake || lastNeverSleep || lastLowPower else { return nil }
        if !savedInCurrentBoot && !restoreSwitchesAfterRestart { return nil }
        if let end = lastExpiresAt, end <= now {
            guard lastLowPower else { return nil }
            return RememberedSwitches(keepAwake: false, neverSleep: false, lowPower: true, expiresAt: nil)
        }
        return RememberedSwitches(keepAwake: lastKeepAwake, neverSleep: lastNeverSleep,
                                  lowPower: lastLowPower, expiresAt: lastExpiresAt)
    }

    /// Byl stav uložen v témže běhu systému? Neznámý čas startu se bere jako restart.
    var savedInCurrentBoot: Bool {
        guard let saved = lastSavedBootTime, let current = Self.systemBootTime() else { return false }
        // kern.boottime se při seřízení hodin může o pár sekund posunout.
        return abs(saved.timeIntervalSince(current)) < 60
    }

    /// Čas startu systému (sysctl kern.boottime); `nil`, když ho systém nevydá.
    nonisolated static func systemBootTime() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, UInt32(mib.count), &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    private nonisolated static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
