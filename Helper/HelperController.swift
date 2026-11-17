import Foundation

/// Všechno, co daemon smí v systému měnit: `pmset disablesleep` a `pmset lowpowermode`.
/// Za protokolem kvůli testům s falešnou implementací.
protocol PowerSettingApplying: Sendable {
    /// Nastaví `disablesleep` na 1 (true) nebo 0 (false). Vrací, zda se to povedlo.
    func setSleepDisabled(_ disabled: Bool) -> Bool
    /// Skutečná systémová hodnota SleepDisabled, nil když ji nelze zjistit.
    func readSleepDisabled() -> Bool?

    /// Právě platná hodnota `lowpowermode` (`pmset -g`), případně že ji Mac nemá.
    func readLowPowerMode() -> LowPowerReading
    /// Hodnoty `lowpowermode` po zdrojích napájení (`pmset -g custom`), nil když je nelze zjistit.
    func readLowPowerProfiles() -> LowPowerState?
    /// Nastaví `lowpowermode` na 1 nebo 0 pro jeden zdroj napájení; `profile == nil` = pro všechny (`-a`).
    func setLowPowerMode(_ enabled: Bool, profile: PowerProfile?) -> Bool
}

struct PowerSourceSnapshot: Sendable {
    let onBattery: Bool
    let percent: Int
}

/// Čtení stavu napájení a teploty.
protocol EnvironmentProbing: Sendable {
    /// nil = Mac nemá baterii nebo stav nelze zjistit (pak se baterie nehlídá).
    func powerSource() -> PowerSourceSnapshot?
    /// `ProcessInfo.ThermalState.rawValue` (0–3).
    func thermalLevel() -> Int
}

/// Stavový automat daemona: dvě na sobě nezávislá držená nastavení – režim „nikdy neusínat"
/// (`disablesleep`) a úsporný režim (`lowpowermode`).
///
/// Společné mají vlastnictví spojením, heartbeat, značku na disku a vracení původní hodnoty
/// (`HeldSetting`). Pojistky baterie a teploty a časovač platí jen pro „nikdy neusínat".
///
/// Veškerý měnitelný stav vlastní jedna sériová fronta `queue`; nic jiného na něj nesahá
/// (proto `@unchecked Sendable`). Veřejné metody se jen zařadí do fronty.
final class HelperController: @unchecked Sendable {

    struct Timing: Sendable {
        var heartbeatTimeout: TimeInterval = HelperConstants.heartbeatTimeout
        /// Jak často se při aktivním režimu „nikdy neusínat" kontroluje baterie a teplota.
        var environmentCheckInterval: TimeInterval = 30
        /// Po jak dlouhé nečinnosti (žádné spojení, nic nedržíme) daemon skončí.
        var idleExitDelay: TimeInterval = 30
        /// Počet okamžitých pokusů o vrácení nastavení.
        var revertAttempts = 3
        var revertAttemptDelay: TimeInterval = 0.5
        /// Když se vrácení nepovede, zkouší se znovu v tomto intervalu, dokud neuspěje.
        var pendingRevertInterval: TimeInterval = 10
        /// Horní mez časovače (30 dní).
        var maxExpiry: TimeInterval = 30 * 24 * 3600
    }

    struct Status: Sendable {
        let sleepDisabled: Bool
        /// Daemon má co vracet: režim drží, čeká na opakované vrácení, nebo po něm zůstala značka.
        let heldByHelper: Bool
    }

    struct LowPowerStatus: Sendable {
        /// Mac úsporný režim má.
        let supported: Bool
        /// Aktuální systémová hodnota (může být zapnutá i odjinud).
        let enabled: Bool
        /// Daemon má co vracet: režim drží, čeká na opakované vrácení, nebo po něm zůstala značka.
        let heldByHelper: Bool
    }

    struct Heartbeat: Sendable {
        let noSleepActive: Bool
        let noSleepStopReason: HelperStopReason
        let lowPowerActive: Bool
        let lowPowerStopReason: HelperStopReason
    }

    typealias ClientID = UUID

    private let queue = DispatchQueue(label: "cz.stayup.StayUp.helper.state")
    private let power: any PowerSettingApplying
    private let environment: any EnvironmentProbing
    private let timing: Timing
    private let onIdle: @Sendable () -> Void

    // Stav – přístup jen z `queue`.
    private var connections = Set<ClientID>()
    private var noSleep: HeldSetting<SleepDisabledSetting>!
    private var lowPower: HeldSetting<LowPowerSetting>!
    // Pojistky a časovač režimu „nikdy neusínat".
    private var batteryThreshold = 0
    private var thermalLimit = 0
    private var expiresAt: TimeInterval?
    private var deadlineWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?

    /// - Parameter onIdle: volá se na interní frontě, když je daemon nečinný a může skončit.
    init(power: any PowerSettingApplying,
         environment: any EnvironmentProbing,
         noSleepMarker: any MarkerStoring<MarkerRecord>,
         lowPowerMarker: any MarkerStoring<LowPowerMarkerRecord>,
         timing: Timing = Timing(),
         onIdle: @escaping @Sendable () -> Void) {
        self.power = power
        self.environment = environment
        self.timing = timing
        self.onIdle = onIdle

        let retry = RevertRetryPolicy(attempts: timing.revertAttempts,
                                      attemptDelay: timing.revertAttemptDelay,
                                      pendingInterval: timing.pendingRevertInterval)
        let afterBackgroundRevert: @Sendable () -> Void = { [weak self] in self?.rescheduleIdleExit() }
        noSleep = HeldSetting(setting: SleepDisabledSetting(power: power),
                              marker: noSleepMarker,
                              queue: queue,
                              retry: retry,
                              afterBackgroundRevert: afterBackgroundRevert)
        lowPower = HeldSetting(setting: LowPowerSetting(power: power),
                               marker: lowPowerMarker,
                               queue: queue,
                               retry: retry,
                               afterBackgroundRevert: afterBackgroundRevert)
    }

    // MARK: - Veřejné rozhraní

    /// Zavolat jednou po startu daemona: zbylá značka znamená, že předchozí běh neskončil čistě.
    func start() {
        queue.async { [self] in
            noSleep.recoverAfterRestart()
            lowPower.recoverAfterRestart()
            rescheduleIdleExit()
        }
    }

    func connectionOpened(_ id: ClientID) {
        queue.async { [self] in
            connections.insert(id)
            rescheduleIdleExit()
        }
    }

    /// Spojení zaniklo (aplikace skončila nebo spadla): vrátit vše, co drželo.
    func connectionClosed(_ id: ClientID) {
        queue.async { [self] in
            connections.remove(id)
            if noSleep.isOwned(by: id) {
                helperLog.notice("Vlastník režimu nikdy neusínat se odpojil, vypínám")
                stopNoSleep(reason: .clientDisconnected)
            }
            if lowPower.isOwned(by: id) {
                helperLog.notice("Vlastník úsporného režimu se odpojil, vypínám")
                lowPower.stop(reason: .clientDisconnected)
            }
            checkDeadlines()
            rescheduleIdleExit()
        }
    }

    func enableNoSleep(client: ClientID,
                       batteryThresholdPercent: Int,
                       thermalLimit: Int,
                       expiresAfter: Double,
                       completion: @escaping @Sendable (_ success: Bool, _ errorMessage: String?) -> Void) {
        queue.async { [self] in
            let error = performEnableNoSleep(client: client,
                                             battery: batteryThresholdPercent,
                                             thermal: thermalLimit,
                                             expiresAfter: expiresAfter)
            checkDeadlines()
            rescheduleIdleExit()
            completion(error == nil, error)
        }
    }

    /// Výslovné vypnutí z aplikace. Idempotentní. Vrátí `disablesleep` na hodnotu před zapnutím;
    /// když daemon nic nedrží a nezbyla po něm značka, neudělá nic (cizí nastavení se nikdy nemění).
    func disableNoSleep(client: ClientID,
                        completion: @escaping @Sendable (_ success: Bool, _ errorMessage: String?) -> Void) {
        queue.async { [self] in
            let ok = releaseNoSleep(reason: .requestedByApp)
            checkDeadlines()
            rescheduleIdleExit()
            completion(ok, ok ? nil : "Nastavení spánku se nepodařilo vrátit. Pomocný proces to bude zkoušet dál.")
        }
    }

    /// Zapne úsporný režim pro všechny zdroje napájení. Na Macu, který ho nemá, vrátí chybu.
    func enableLowPower(client: ClientID,
                        completion: @escaping @Sendable (_ success: Bool, _ errorMessage: String?) -> Void) {
        queue.async { [self] in
            let error = performEnableLowPower(client: client)
            checkDeadlines()
            rescheduleIdleExit()
            completion(error == nil, error)
        }
    }

    /// Výslovné vypnutí z aplikace. Idempotentní. Vrátí `lowpowermode` na hodnoty před zapnutím;
    /// když daemon nic nedrží a nezbyla po něm značka, neudělá nic.
    func disableLowPower(client: ClientID,
                         completion: @escaping @Sendable (_ success: Bool, _ errorMessage: String?) -> Void) {
        queue.async { [self] in
            let ok = lowPower.release(reason: .requestedByApp)
            checkDeadlines()
            rescheduleIdleExit()
            completion(ok, ok ? nil : "Úsporný režim se nepodařilo vrátit. Pomocný proces to bude zkoušet dál.")
        }
    }

    /// Jeden heartbeat udržuje naživu všechna nastavení, která `client` drží.
    func heartbeat(client: ClientID, completion: @escaping @Sendable (Heartbeat) -> Void) {
        queue.async { [self] in
            let noSleepActive = noSleep.heartbeat(from: client)
            let lowPowerActive = lowPower.heartbeat(from: client)
            completion(Heartbeat(noSleepActive: noSleepActive,
                                 noSleepStopReason: noSleepActive ? .none : noSleep.lastStopReason,
                                 lowPowerActive: lowPowerActive,
                                 lowPowerStopReason: lowPowerActive ? .none : lowPower.lastStopReason))
        }
    }

    func status(completion: @escaping @Sendable (Status) -> Void) {
        queue.async { [self] in
            // Když skutečnou hodnotu nelze přečíst, vycházíme z toho, co víme: držíme-li režim, je zapnutý.
            let actual = power.readSleepDisabled() ?? (noSleep.held || noSleep.pendingRevert)
            completion(Status(sleepDisabled: actual, heldByHelper: noSleep.hasSomethingToRevert))
        }
    }

    func lowPowerStatus(completion: @escaping @Sendable (LowPowerStatus) -> Void) {
        queue.async { [self] in
            let ours = lowPower.held || lowPower.pendingRevert
            let supported: Bool
            let enabled: Bool
            switch power.readLowPowerMode() {
            case .value(let value): (supported, enabled) = (true, value)
            case .unsupported: (supported, enabled) = (false, false)
            // Hodnotu nelze přečíst: vycházíme z toho, co víme (držíme-li režim, Mac ho má a je zapnutý).
            case .unreadable: (supported, enabled) = (ours, ours)
            }
            completion(LowPowerStatus(supported: supported,
                                      enabled: enabled,
                                      heldByHelper: lowPower.hasSomethingToRevert))
        }
    }

    /// Změnil se zdroj napájení nebo tepelný stav – zkontrolovat hned. Týká se jen „nikdy neusínat".
    func environmentChanged() {
        queue.async { [self] in
            guard noSleep.held else { return }
            if let reason = environmentViolation() {
                stopNoSleep(reason: reason)
                checkDeadlines()
                rescheduleIdleExit()
            }
        }
    }

    /// Ukončení daemona (SIGTERM/SIGINT): vrátit obě nastavení a pak zavolat `completion`.
    /// `reverted == false` znamená, že některá značka zůstala na disku; daemon pak má skončit s chybou,
    /// aby ho launchd (KeepAlive › SuccessfulExit = false) spustil znovu a vrácení dokončil `start()`.
    func shutdown(completion: @escaping @Sendable (_ reverted: Bool) -> Void) {
        queue.async { [self] in
            idleWork?.cancel()
            let noSleepOK = releaseNoSleep(reason: .helperRestarted)
            let lowPowerOK = lowPower.release(reason: .helperRestarted)
            deadlineWork?.cancel()
            deadlineWork = nil
            // Proces končí, další pokus na pozadí by stejně neproběhl.
            noSleep.cancelBackgroundRevert()
            lowPower.cancelBackgroundRevert()
            completion(noSleepOK && lowPowerOK && !noSleep.markerExists && !lowPower.markerExists)
        }
    }

    /// Počká, až fronta zpracuje vše dosud zařazené (pro testy).
    func drain() {
        queue.sync {}
    }

    // MARK: - Interní logika (jen na `queue`)

    private func now() -> TimeInterval {
        // CLOCK_MONOTONIC na macOS běží i během spánku, takže časovač spánkem „neprodlouží".
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// Vrací nil při úspěchu, jinak chybovou zprávu pro uživatele.
    private func performEnableNoSleep(client: ClientID, battery: Int, thermal: Int, expiresAfter: Double) -> String? {
        // Validace vstupu: záporné a nečíselné hodnoty odmítnout, příliš velké oříznout.
        guard battery >= 0, thermal >= 0, expiresAfter.isFinite, expiresAfter >= 0 else {
            helperLog.error("Odmítnuty neplatné parametry enableNoSleep")
            return "Neplatné parametry požadavku."
        }
        let battery = min(battery, 100)
        let thermal = min(thermal, 3)
        let expiry = min(expiresAfter, timing.maxExpiry)

        // Nezapínat (a případně rovnou vypnout), když už teď platí některá z ochran.
        if let reason = environmentViolation(battery: battery, thermal: thermal) {
            if noSleep.held { stopNoSleep(reason: reason) }
            return reason == .lowBattery
                ? "Baterie je pod nastavenou hranicí, režim nejde zapnout."
                : "Mac je příliš zahřátý, režim nejde zapnout."
        }

        let enabledAt = Date()
        let failure = noSleep.engage(client: client) { previous in
            MarkerRecord(enabledAt: enabledAt,
                         batteryThresholdPercent: battery,
                         thermalLimit: thermal,
                         expiresAfter: expiry,
                         previousSleepDisabled: previous)
        }
        switch failure {
        case .markerWrite?:
            return "Nepodařilo se uložit záznam pro bezpečné obnovení, režim zůstal vypnutý."
        case .settingWrite?, .originalUnreadable?:
            if !noSleep.held { expiresAt = nil }
            return "Nastavení spánku se nepodařilo změnit."
        case nil:
            break
        }

        batteryThreshold = battery
        thermalLimit = thermal
        expiresAt = expiry > 0 ? now() + expiry : nil
        return nil
    }

    /// Vrací nil při úspěchu, jinak chybovou zprávu pro uživatele.
    private func performEnableLowPower(client: ClientID) -> String? {
        switch power.readLowPowerMode() {
        case .unsupported:
            helperLog.notice("Úsporný režim tento Mac nemá, nezapínám")
            return "Tento Mac úsporný režim nemá."
        case .unreadable:
            return "Stav úsporného režimu se nepodařilo zjistit, režim zůstal beze změny."
        case .value:
            break
        }

        let enabledAt = Date()
        let failure = lowPower.engage(client: client) { previous in
            LowPowerMarkerRecord(enabledAt: enabledAt, previous: previous)
        }
        switch failure {
        case .markerWrite?:
            return "Nepodařilo se uložit záznam pro bezpečné obnovení, úsporný režim zůstal vypnutý."
        case .originalUnreadable?:
            return "Původní nastavení úsporného režimu se nepodařilo zjistit, režim zůstal beze změny."
        case .settingWrite?:
            return "Úsporný režim se nepodařilo zapnout."
        case nil:
            return nil
        }
    }

    /// Ukončí držení režimu „nikdy neusínat" a vrátí nastavení. Vrací, zda se vrácení povedlo hned.
    @discardableResult
    private func stopNoSleep(reason: HelperStopReason) -> Bool {
        expiresAt = nil
        return noSleep.stop(reason: reason)
    }

    private func releaseNoSleep(reason: HelperStopReason) -> Bool {
        expiresAt = nil
        return noSleep.release(reason: reason)
    }

    private func environmentViolation() -> HelperStopReason? {
        environmentViolation(battery: batteryThreshold, thermal: thermalLimit)
    }

    private func environmentViolation(battery: Int, thermal: Int) -> HelperStopReason? {
        if battery > 0, let source = environment.powerSource(),
           source.onBattery, source.percent < battery {
            return .lowBattery
        }
        if thermal > 0, environment.thermalLevel() >= thermal {
            return .thermal
        }
        return nil
    }

    /// Zkontroluje všechny lhůty a naplánuje další probuzení na nejbližší z nich.
    /// Časovač, baterie a teplota platí jen pro „nikdy neusínat"; heartbeat pro obě nastavení.
    private func checkDeadlines() {
        deadlineWork?.cancel()
        deadlineWork = nil

        if noSleep.held {
            if let expiresAt, now() >= expiresAt {
                stopNoSleep(reason: .timerExpired)
            } else if noSleep.heartbeatAge >= timing.heartbeatTimeout {
                stopNoSleep(reason: .heartbeatTimeout)
            } else if let reason = environmentViolation() {
                stopNoSleep(reason: reason)
            }
        }
        if lowPower.held, lowPower.heartbeatAge >= timing.heartbeatTimeout {
            lowPower.stop(reason: .heartbeatTimeout)
        }
        guard noSleep.held || lowPower.held else {
            rescheduleIdleExit()
            return
        }

        // Zpoždění místo absolutního času: heartbeat a časovač se měří různými hodinami.
        var delay = TimeInterval.infinity
        if noSleep.held {
            delay = min(timing.environmentCheckInterval, timing.heartbeatTimeout - noSleep.heartbeatAge)
            if let expiresAt { delay = min(delay, expiresAt - now()) }
        }
        if lowPower.held {
            delay = min(delay, timing.heartbeatTimeout - lowPower.heartbeatAge)
        }
        let work = DispatchWorkItem { [weak self] in self?.checkDeadlines() }
        deadlineWork = work
        queue.asyncAfter(deadline: .now() + max(0.05, delay), execute: work)
    }

    /// Je co vracet? Dokud ano, daemon nesmí čistě skončit.
    private var hasSomethingToRevert: Bool {
        noSleep.hasSomethingToRevert || lowPower.hasSomethingToRevert
    }

    /// Daemon skončí, když nemá spojení, nic nedrží, nečeká na opakované vrácení a nezbyla žádná značka.
    /// Čistý konec (exit 0) launchd neobnovuje, proto se nesmí stát, dokud je co vracet.
    private func rescheduleIdleExit() {
        idleWork?.cancel()
        idleWork = nil
        guard connections.isEmpty, !hasSomethingToRevert else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connections.isEmpty, !self.hasSomethingToRevert else { return }
            helperLog.info("Nečinnost, daemon končí")
            self.onIdle()
        }
        idleWork = work
        queue.asyncAfter(deadline: .now() + timing.idleExitDelay, execute: work)
    }
}
