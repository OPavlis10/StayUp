import Foundation
import Observation
import notify

/// Stav pomocného procesu z pohledu panelu.
enum HelperState: Sendable, Equatable {
    case notRegistered
    case requiresApproval
    case ready
    /// Daemon je povolený, ale nejde s ním mluvit (jiná verze, chyba spojení). Text je důvod.
    case unavailable(String)
    /// V balíčku aplikace chybí popis služby, takže ji nejde zaregistrovat (neúplné sestavení).
    case missingFromBundle
}

/// Jediný objekt, se kterým mluví UI: oba přepínače spánku, úsporný režim, časovač a bezpečnostní pojistky.
@MainActor
@Observable
final class SleepController {
    // MARK: - Stav pro UI

    /// Přepínač A, jak ho nastavil uživatel.
    private(set) var keepAwakeOn = false
    /// Přepínač B.
    private(set) var neverSleepOn = false
    /// A || B: assertion je držena, kdykoli je zapnutý aspoň jeden přepínač.
    var effectiveKeepAwake: Bool { keepAwakeOn || neverSleepOn }
    /// Úsporný režim zapnutý tímto přepínačem (drží ho daemon). Na A a B nezávisí.
    private(set) var lowPowerOn = false
    /// Má Mac úsporný režim? `nil`, dokud daemon neodpověděl.
    private(set) var lowPowerSupported: Bool?
    /// Úsporný režim podle systému (může ho mít zapnutý uživatel v Nastavení systému).
    private(set) var systemLowPowerOn = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var helperState: HelperState = .notRegistered
    /// Průběh nebo výsledek nové registrace pomocného procesu; ukazuje ho karta přepínače B.
    private(set) var helperNote: String?
    /// Uživatel zapnul režim B, ale pomocný proces čeká na povolení: do této doby se režim zapne
    /// sám, jakmile povolení přijde. `nil` = na nic se nečeká.
    private(set) var neverSleepPendingUntil: Date?
    /// Totéž pro úsporný režim.
    private(set) var lowPowerPendingUntil: Date?
    private(set) var isBusy = false
    /// Konec společného časovače; `nil` = do vypnutí.
    private(set) var expiresAt: Date?
    /// Poslední chyba nebo vysvětlení automatického vypnutí.
    private(set) var lastMessage: String?
    /// Klidné sdělení, proč aplikace bdění sama ukončila (AI nepracuje, výpadek sítě). Není to chyba.
    private(set) var lastNotice: String?
    private(set) var batteryPercent: Int?
    private(set) var isOnBattery = false
    private(set) var hasBattery = false
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    /// Zvolená doba (uložená v nastavení jako výchozí).
    var duration: AwakeDuration { settings.defaultDuration }

    let settings: AppSettings

    // MARK: - Vnitřní stav

    /// Odkud zapnutí přichází: od uživatele (časovač podle zvolené doby), nebo z obnovy po spuštění
    /// (zapamatovaný konec časovače).
    private enum Activation {
        case fresh
        case restored(Date?)
    }

    private enum Operation {
        /// `waitUntil`: když je potřeba povolení pomocného procesu, do kdy se má zapnutí dokončit samo
        /// (`nil` = nečekat, např. při obnově po spuštění).
        case turnOn(Activation, waitUntil: Date?)
        case turnOff(explanation: String?, notify: Bool)
        /// Vypne B (přes daemon) a potom A; `notice` se ukáže v panelu.
        case stopAll(notice: String)
        case resync
    }

    private enum LowPowerOperation {
        case turnOn(waitUntil: Date?)
        case turnOff(explanation: String?)
    }

    /// Který režim držený daemonem má zůstat ušetřen, když se ruší spojení.
    private enum HelperMode {
        case neverSleep
        case lowPower
    }

    let notifier: Notifier

    @ObservationIgnored private let client: HelperClient
    /// `false` při zkušebním spuštění (testy, náhledy): daemon se neregistruje a nic se mu neposílá,
    /// aby zkouška nezměnila spánek Macu ani nezasáhla do běžící aplikace.
    @ObservationIgnored private let usesHelper: Bool
    @ObservationIgnored private let assertion = AwakeAssertion()

    @ObservationIgnored private var pendingOperation: Operation?
    /// Úsporný režim má vlastní čekající požadavek, aby ho nepřepsal požadavek na režim B (a naopak).
    @ObservationIgnored private var pendingLowPower: LowPowerOperation?
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var busyCount = 0

    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var safetyTask: Task<Void, Never>?
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    /// Odložená kontrola poté, co systém ohlásil vypnutí úsporného režimu, který drží daemon.
    @ObservationIgnored private var lowPowerExternalCheck: Task<Void, Never>?
    /// Čekání na povolení pomocného procesu; běží, jen dokud nějaký přepínač čeká.
    @ObservationIgnored private var approvalTask: Task<Void, Never>?
    /// Běží zapnutí přepínačů, které čekaly na povolení; druhé se mezitím nespustí.
    @ObservationIgnored private var resuming = false
    /// Daemon je povolený, ale při posledním `ensureHelperReady` ještě neodpovídal (chyba spojení,
    /// vypršení času) a čekající zapnutí to smí zkusit znovu.
    @ObservationIgnored private var daemonNotAnsweringYet = false
    /// Kolikrát už čekající zapnutí narazilo na neodpovídající daemon.
    @ObservationIgnored private var connectionRetries = 0
    @ObservationIgnored private var reregistering = false
    @ObservationIgnored private var thresholdObservation = 0

    @ObservationIgnored private var started = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var powerNotifyToken: Int32 = NOTIFY_TOKEN_INVALID
    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lowPowerObserver: (any NSObjectProtocol)?
    /// Roste s každým zapnutím režimu drženého daemonem; heartbeat odeslaný před zapnutím se nevyhodnocuje.
    @ObservationIgnored private var helperModeEpoch = 0

    private static let safetyCheckInterval: Duration = .seconds(15)
    /// Jak dlouho po zapnutí přepínače se čeká na povolení pomocného procesu.
    private static let approvalWait: TimeInterval = 10 * 60
    private static let approvalPollInterval: Duration = .seconds(3)
    /// Kolik pokusů (po `approvalPollInterval`) dostane čerstvě povolený daemon, než se chyba
    /// spojení ukáže a čekání skončí.
    private static let maxConnectionRetries = 6

    /// Je popis služby daemonu v balíčku aplikace? Bez něj ji systém zaregistrovat nemůže.
    private static let daemonPlistInBundle: Bool = {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(HelperConstants.daemonPlistName)
        return FileManager.default.fileExists(atPath: url.path)
    }()

    init(settings: AppSettings, client: HelperClient = HelperClient(), notifier: Notifier = Notifier(),
         usesHelper: Bool = true) {
        self.settings = settings
        self.client = client
        self.notifier = notifier
        self.usesHelper = usesHelper
    }

    // MARK: - Životní cyklus

    /// Při startu aplikace: obnoví zapamatovaný stav a uklidí nastavení, které po sobě nechal daemon.
    func start() {
        guard !started else { return }
        started = true

        client.setConnectionHandler { [weak self] event in
            Task { @MainActor in self?.connectionChanged(event) }
        }
        installPowerObservers()

        Task { [weak self] in
            await self?.refreshPower()
            await self?.refreshHelperState()
            await self?.restoreRememberedSwitches()
            await self?.clearStaleNoSleep()
            await self?.refreshLowPowerStatus(clearStale: true)
        }
    }

    /// Při ukončení aplikace: uvolní assertion a s omezeným čekáním (2 s) řekne daemonu, ať oba režimy vypne.
    /// Zapamatovaný stav přepínačů se nemění, aby ho další spuštění mohlo obnovit.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true

        let hadHelperMode = neverSleepOn || lowPowerOn
        pendingOperation = nil
        pendingLowPower = nil
        stopNeverSleepLoops()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        lowPowerExternalCheck?.cancel()
        lowPowerExternalCheck = nil
        approvalTask?.cancel()
        approvalTask = nil
        neverSleepPendingUntil = nil
        lowPowerPendingUntil = nil
        removePowerObservers()
        client.setConnectionHandler(nil)

        keepAwakeOn = false
        neverSleepOn = false
        lowPowerOn = false
        expiresAt = nil
        assertion.release()

        // Jen když tato aplikace mohla některý režim opravdu zapnout (je zapnutý, nebo běží operace,
        // která ho mohla stihnout zapnout). Jinak se daemonu nic neposílá.
        if usesHelper, hadHelperMode || draining {
            client.disableAllBlocking(timeout: 2)
        }
        // Zánik spojení je druhá pojistka: daemon má režim vázaný na spojení.
        client.close()
    }

    // MARK: - Přepínač A

    func setKeepAwake(_ on: Bool) {
        setKeepAwake(on, activation: .fresh)
    }

    private func setKeepAwake(_ on: Bool, activation: Activation) {
        guard !isShutDown, on != keepAwakeOn else { return }
        clearMessages()
        if on {
            let expiry = expiryForActivation(activation)
            guard assertion.acquire() else {
                lastMessage = String(localized: "Nepodařilo se zabránit uspání Macu. Zkuste to prosím znovu.")
                return
            }
            let wasActive = effectiveKeepAwake
            keepAwakeOn = true
            if !wasActive { setExpiry(expiry) }
        } else {
            keepAwakeOn = false
            applyAssertion()
            if !effectiveKeepAwake { setExpiry(nil) }
        }
        remember()
    }

    // MARK: - Přepínač B

    /// Zapne nebo vypne režim B. Při zapnutí podle potřeby zaregistruje daemon; když je potřeba
    /// schválení v Nastavení systému, nastaví `helperState` (nic neotevírá) a záměr si
    /// `approvalWait` pamatuje: po povolení se režim zapne sám. Vypnutí přepínače čekání ruší.
    func setNeverSleep(_ on: Bool) async {
        guard !isShutDown else { return }
        if on {
            await submit(.turnOn(.fresh, waitUntil: Date().addingTimeInterval(Self.approvalWait)))
        } else {
            cancelPending(.neverSleep)
            await submit(.turnOff(explanation: nil, notify: false))
        }
    }

    // MARK: - Úsporný režim

    /// Zapne nebo vypne úsporný režim macOS přes daemon. Registrace, schválení i čekání na ně
    /// jako u režimu B.
    func setLowPower(_ on: Bool) async {
        guard !isShutDown else { return }
        if on {
            await submitLowPower(.turnOn(waitUntil: Date().addingTimeInterval(Self.approvalWait)))
        } else {
            cancelPending(.lowPower)
            await submitLowPower(.turnOff(explanation: nil))
        }
    }

    // MARK: - Automatické ukončení bdění

    /// Vypne zapnuté přepínače spánku (B řádně přes daemon, potom A) a ukáže v panelu klidné sdělení.
    /// Úsporného režimu se netýká.
    func stopKeepAwake(notice: String) async {
        guard !isShutDown, effectiveKeepAwake else { return }
        await submit(.stopAll(notice: notice))
    }

    // MARK: - Doba

    /// Platí pro právě zapnuté přepínače (časovač běží od teď znovu) i pro příští zapnutí.
    func setDuration(_ d: AwakeDuration) {
        settings.defaultDuration = d
        guard effectiveKeepAwake else { return }
        setExpiry(d.seconds.map { Date().addingTimeInterval($0) })
        remember()
        if neverSleepOn { requestResync() }
    }

    // MARK: - Display

    func sleepDisplayNow() {
        Task { [weak self] in
            let succeeded = await DisplaySleeper.sleepNow()
            if !succeeded {
                self?.lastMessage = String(localized: "Displej se nepodařilo uspat.")
            }
        }
    }

    // MARK: - Pomocný proces

    func registerHelper() async {
        guard !isShutDown else { return }
        guard usesHelper else {
            lastMessage = Self.diagnosticMessage
            return
        }
        beginBusy()
        defer { endBusy() }
        helperNote = nil
        do {
            apply(registration: try await client.register())
            // Čekání na povolení popisuje přímo karta přepínače B podle `helperState`.
            if helperState == .ready || helperState == .requiresApproval {
                lastMessage = nil
            }
            if helperState == .ready { await refreshLowPowerStatus(clearStale: false) }
        } catch {
            lastMessage = error.localizedDescription
            await refreshHelperState()
        }
    }

    /// „Zaregistrovat znovu": službu daemonu odregistruje a zaregistruje, takže systém spustí
    /// daemon z aktuální aplikace (pomůže po aktualizaci nebo při jiné verzi protokolu).
    /// Všechna volání systému běží mimo hlavní vlákno.
    func reregisterHelper() async {
        guard !isShutDown, !reregistering else { return }
        guard usesHelper else {
            lastMessage = Self.diagnosticMessage
            return
        }
        reregistering = true
        defer { reregistering = false }
        clearMessages()

        // Odregistrace daemon ukončí; režimy, které drží, se proto nejdřív řádně vypnou.
        cancelPending(.neverSleep)
        cancelPending(.lowPower)
        if neverSleepOn { await submit(.turnOff(explanation: nil, notify: false)) }
        if lowPowerOn { await submitLowPower(.turnOff(explanation: nil)) }
        guard !isShutDown else { return }

        beginBusy()
        defer { endBusy() }
        helperNote = String(localized: "Registruji pomocný proces znovu…")

        do {
            try await client.unregister()
        } catch {
            // Neregistrovanou službu systém odregistrovat odmítne; to nevadí. Vadí jen, když
            // registrace po chybě opravdu zůstala.
            let remaining = await client.registrationStatus()
            if remaining == .enabled || remaining == .requiresApproval {
                helperNote = nil
                lastMessage = error.localizedDescription
                return
            }
        }
        guard !isShutDown else { return }

        let registration: HelperRegistration
        do {
            do {
                registration = try await client.register()
            } catch {
                // Těsně po odregistraci systém novou registraci občas odmítne; jeden další pokus.
                try? await Task.sleep(for: .seconds(1))
                registration = try await client.register()
            }
        } catch {
            helperNote = nil
            lastMessage = error.localizedDescription
            apply(registration: await client.registrationStatus(), keepsUnavailable: false)
            return
        }
        guard !isShutDown else { return }

        switch registration {
        case .enabled:
            do {
                try await verifyHelperVersion()
            } catch {
                helperNote = nil
                helperState = .unavailable(error.localizedDescription)
                return
            }
            helperState = .ready
            helperNote = String(localized: "Pomocný proces je znovu zaregistrovaný a připravený.")
            await refreshLowPowerStatus(clearStale: false)
        case .requiresApproval:
            helperState = .requiresApproval
            helperNote = String(localized: "Pomocný proces je znovu zaregistrovaný, ještě ho povolte.")
        case .notRegistered, .notFound:
            helperNote = nil
            apply(registration: registration, keepsUnavailable: false)
            lastMessage = String(localized: "Pomocný proces se nepodařilo znovu zaregistrovat.")
        }
    }

    func openLoginItemsSettings() {
        HelperClient.openSystemSettingsLoginItems()
    }

    /// Znovu zjistí stav registrace. Když mezitím přišlo povolení a některý přepínač na něj čeká,
    /// rovnou ho zapne.
    func refreshHelperState() async {
        let registration = await client.registrationStatus()
        apply(registration: registration)
        guard registration == .enabled else { return }
        await recheckUnavailable()
        resumePending()
    }

    /// Daemon je povolený, ale naposledy s ním nešlo mluvit: zkusí to znovu, aby jednorázová chyba
    /// (vypršení času, spojení) nezůstala v kartě napořád. Jiná verze protokolu selže znovu a zůstane.
    private func recheckUnavailable() async {
        guard usesHelper, !isShutDown, !draining, !reregistering, case .unavailable = helperState else { return }
        do {
            try await verifyHelperVersion()
        } catch {
            if !isShutDown, !draining, !reregistering, case .unavailable = helperState {
                helperState = .unavailable(error.localizedDescription)
            }
            return
        }
        if !isShutDown, !draining, !reregistering, case .unavailable = helperState { helperState = .ready }
    }

    /// Znovu načte baterii a tepelný stav (např. při otevření panelu). Jinak se hodnoty
    /// aktualizují samy při změně napájení a každých 15 s, když je zapnutý režim B.
    func refreshPower() async {
        let reading = await SafetyMonitor.currentPower()
        hasBattery = reading.hasBattery
        batteryPercent = reading.batteryPercent
        isOnBattery = reading.isOnBattery
        thermalState = SafetyMonitor.thermalState
        evaluateSafety()
    }

    // MARK: - Fronta operací s daemonem

    /// Operace s daemonem běží jedna po druhé; čekající požadavek přepíše novější.
    private func submit(_ operation: Operation) async {
        if case .resync = operation, pendingOperation != nil { return }
        // Čekající ukončení všeho už vypnutí B obsahuje; nesmí ho přepsat.
        if case .stopAll = pendingOperation, case .turnOff = operation {
            await drain()
            return
        }
        pendingOperation = operation
        await drain()
    }

    private func submitLowPower(_ operation: LowPowerOperation) async {
        pendingLowPower = operation
        await drain()
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        beginBusy()
        while !isShutDown {
            if let next = pendingOperation {
                pendingOperation = nil
                switch next {
                case .turnOn(let activation, let waitUntil):
                    await performTurnOn(activation, waitUntil: waitUntil)
                case .turnOff(let explanation, let notify):
                    await performTurnOff(explanation: explanation, notify: notify)
                case .stopAll(let notice):
                    await performStopAll(notice: notice)
                case .resync:
                    await performResync()
                }
            } else if let next = pendingLowPower {
                pendingLowPower = nil
                switch next {
                case .turnOn(let waitUntil):
                    await performLowPowerOn(waitUntil: waitUntil)
                case .turnOff(let explanation):
                    await performLowPowerOff(explanation: explanation)
                }
            } else {
                break
            }
        }
        draining = false
        endBusy()
    }

    /// Kroky společné režimu B i úspornému režimu: registrace daemonu a kontrola verze protokolu.
    /// Když je potřeba schválení v Nastavení systému, jen nastaví `helperState` (návod ukáže karta).
    /// `retriesConnection`: zapnutí čeká na povolení a daemon mohl být povolen teprve teď; když
    /// ještě neodpovídá, chyba se neukáže a nastaví se `daemonNotAnsweringYet`.
    private func ensureHelperReady(unavailableMessage: String, retriesConnection: Bool = false) async -> Bool {
        daemonNotAnsweringYet = false
        guard usesHelper else {
            lastMessage = Self.diagnosticMessage
            return false
        }
        // 1. Registrace daemonu. `.notFound` hlásí systém i u dosud neregistrované služby.
        var registration = await client.registrationStatus()
        if registration == .notRegistered || registration == .notFound {
            do {
                registration = try await client.register()
            } catch {
                apply(registration: await client.registrationStatus())
                lastMessage = error.localizedDescription
                return false
            }
        }
        // „Povoleno" se do panelu propíše až po ověření verze, aby karta mezitím neproblikla.
        if registration != .enabled { apply(registration: registration) }
        switch registration {
        case .enabled:
            break
        case .requiresApproval:
            return false   // návod zobrazuje karta přepínače B podle `helperState`
        case .notRegistered, .notFound:
            lastMessage = unavailableMessage
            return false
        }

        // 2. Verze protokolu.
        do {
            try await verifyHelperVersion()
        } catch {
            if retriesConnection, Self.isConnectionFailure(error) {
                daemonNotAnsweringYet = true
                return false
            }
            helperState = .unavailable(error.localizedDescription)   // text ukáže karta přepínače B
            return false
        }
        if helperState != .ready { helperState = .ready }
        return true
    }

    /// Chyba, po které má smysl zkusit to za chvíli znovu (na rozdíl od jiné verze protokolu).
    private static func isConnectionFailure(_ error: any Error) -> Bool {
        switch error {
        case HelperClientError.connection, HelperClientError.timeout: true
        default: false
        }
    }

    /// Smí čekající zapnutí (se lhůtou `waitUntil`) zkusit neodpovídající daemon znovu?
    private func canRetryConnection(pending: Date?, waitUntil: Date?) -> Bool {
        guard let waitUntil, pending == waitUntil else { return false }
        return connectionRetries < Self.maxConnectionRetries
    }

    /// Ověří, že daemon odpovídá a mluví stejnou verzí protokolu. Čerstvě registrovaný daemon
    /// může potřebovat chvilku, proto se chyba spojení jednou zopakuje.
    private func verifyHelperVersion() async throws {
        do {
            _ = try await client.checkedStatus()
        } catch HelperClientError.connection {
            try? await Task.sleep(for: .milliseconds(700))
            _ = try await client.checkedStatus()
        }
    }

    // MARK: - Čekání na povolení pomocného procesu

    /// Po neúspěšném `ensureHelperReady`: když chybí jen povolení (nebo čerstvě povolený daemon
    /// ještě neodpovídá) a zapnutí si vyžádal uživatel, záměr se zapamatuje do `deadline`; jinak
    /// se případné čekání zruší.
    private func rememberPending(_ mode: HelperMode, until deadline: Date?) {
        let notAnswering = daemonNotAnsweringYet
        daemonNotAnsweringYet = false
        guard usesHelper, !isShutDown, helperState == .requiresApproval || notAnswering,
              let deadline, deadline > Date() else {
            cancelPending(mode)
            return
        }
        if notAnswering { connectionRetries += 1 }
        switch mode {
        case .neverSleep: if neverSleepPendingUntil != deadline { neverSleepPendingUntil = deadline }
        case .lowPower: if lowPowerPendingUntil != deadline { lowPowerPendingUntil = deadline }
        }
        syncApprovalWatch()
    }

    private func cancelPending(_ mode: HelperMode) {
        switch mode {
        case .neverSleep: if neverSleepPendingUntil != nil { neverSleepPendingUntil = nil }
        case .lowPower: if lowPowerPendingUntil != nil { lowPowerPendingUntil = nil }
        }
        syncApprovalWatch()
    }

    /// Stav registrace se zjišťuje po `approvalPollInterval`, jen dokud nějaký přepínač čeká
    /// (nejdéle `approvalWait`); jinak úloha neexistuje.
    private func syncApprovalWatch() {
        let needed = (neverSleepPendingUntil != nil || lowPowerPendingUntil != nil) && !isShutDown
        guard needed else {
            approvalTask?.cancel()
            approvalTask = nil
            connectionRetries = 0
            return
        }
        guard approvalTask == nil else { return }
        approvalTask = Task { [weak self, client] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.approvalPollInterval) } catch { return }
                let registration = await client.registrationStatus()
                guard !Task.isCancelled, let self else { return }
                self.approvalTick(registration)
            }
        }
    }

    private func approvalTick(_ registration: HelperRegistration) {
        guard !isShutDown else { return }
        dropExpiredPendings()
        apply(registration: registration)
        if registration == .enabled {
            resumePending()
        } else {
            syncApprovalWatch()
        }
    }

    /// Čekání, kterému vypršela lhůta, se zruší. Volá se na každé cestě, která by mohla čekající
    /// přepínač zapnout, takže lhůta platí i mimo pravidelnou kontrolu.
    private func dropExpiredPendings() {
        let now = Date()
        var expired = false
        if let until = neverSleepPendingUntil, until <= now {
            neverSleepPendingUntil = nil
            expired = true
        }
        if let until = lowPowerPendingUntil, until <= now {
            lowPowerPendingUntil = nil
            expired = true
        }
        if expired {
            lastMessage = String(localized: "Pomocný proces nebyl do 10 minut povolen, přepínač proto zůstal vypnutý. Po povolení ho zapněte znovu.")
        }
    }

    /// Povolení přišlo: zapne přepínače, které na něj čekaly. Čekání ruší až samotné zapnutí
    /// (nebo jeho neúspěch), takže přepínač mezitím v panelu neproblikne. Běží nejvýš jedno
    /// takové zapnutí; když už nic nečeká, kontrola povolení se zastaví.
    private func resumePending() {
        guard !isShutDown, !resuming else { return }
        dropExpiredPendings()
        let neverSleep = neverSleepPendingUntil
        let lowPower = lowPowerPendingUntil
        guard neverSleep != nil || lowPower != nil else {
            syncApprovalWatch()
            return
        }
        approvalTask?.cancel()
        approvalTask = nil
        resuming = true
        Task { [weak self] in
            guard let self else { return }
            if let neverSleep, self.neverSleepPendingUntil == neverSleep {
                await self.submit(.turnOn(.fresh, waitUntil: neverSleep))
            }
            if let lowPower, self.lowPowerPendingUntil == lowPower {
                await self.submitLowPower(.turnOn(waitUntil: lowPower))
            }
            self.resuming = false
            // Kdo ještě čeká (povolení mezitím zmizelo, daemon ještě neodpovídá), hlídá se dál.
            self.syncApprovalWatch()
        }
    }

    /// Vlastní zrušení spojení vrátí v daemonu oba režimy. Ten, o který právě nejde (`sparing`),
    /// se proto musí vypnout i v aplikaci; obsluha spojení se při vlastním zrušení nevolá.
    private func resetConnection(sparing mode: HelperMode) {
        client.invalidate()
        switch mode {
        case .neverSleep:
            if lowPowerOn { lowPowerDropped(reason: .clientDisconnected) }
        case .lowPower:
            if neverSleepOn { requestAutoOff(explanation: explanation(for: .clientDisconnected)) }
        }
    }

    private func performTurnOn(_ activation: Activation, waitUntil: Date?) async {
        guard !neverSleepOn else {
            cancelPending(.neverSleep)
            return
        }
        clearMessages()

        // 1. a 2. Registrace daemonu a verze protokolu.
        guard await ensureHelperReady(
            unavailableMessage: String(localized: "Pomocný proces není k dispozici, režim Nikdy nevypínat nejde zapnout."),
            retriesConnection: canRetryConnection(pending: neverSleepPendingUntil, waitUntil: waitUntil)
        ) else {
            rememberPending(.neverSleep, until: waitUntil)
            return
        }
        cancelPending(.neverSleep)

        // 3. Pojistky: nezapínat, když by se režim hned zase vypnul.
        await refreshPower()
        if let reason = currentSafetyStop() {
            lastMessage = String(localized: "Režim Nikdy nevypínat teď nejde zapnout: \(reason.explanation).")
            return
        }
        guard !isShutDown else { return }

        // 4. Zapnutí.
        let expiry = expiryForActivation(activation)
        do {
            try await client.enableNoSleep(batteryThresholdPercent: settings.batteryThresholdPercent,
                                           thermalLimit: settings.thermalLimit,
                                           expiresAfter: Self.remainingSeconds(until: expiry))
        } catch {
            // Bez jednoznačné odpovědi (vypršení času, chyba spojení) mohl daemon zapnutí ještě
            // dokončit. Zrušení spojení ho přiměje nastavení vrátit (režim je vázaný na spojení).
            // `.helperFailed` znamená, že daemon odpověděl a vrátil si vše sám.
            if case HelperClientError.helperFailed = error {} else { resetConnection(sparing: .neverSleep) }
            lastMessage = error.localizedDescription
            return
        }
        guard !isShutDown else { return }   // shutdown() už daemonu řekl, ať režim vypne

        let wasActive = effectiveKeepAwake
        helperModeEpoch += 1
        neverSleepOn = true
        applyAssertion()
        if !wasActive { setExpiry(expiry) }
        remember()
        startNeverSleepLoops()
    }

    /// Vrací text chyby, když se vypnutí nepodařilo potvrdit.
    @discardableResult
    private func performTurnOff(explanation: String?, notify: Bool) async -> String? {
        cancelPending(.neverSleep)
        guard neverSleepOn else { return nil }
        neverSleepOn = false
        stopNeverSleepLoops()
        applyAssertion()                      // A zůstává, jak ji nechal uživatel
        if !effectiveKeepAwake { setExpiry(nil) }
        remember()

        let message = explanation.map(Notifier.neverSleepStoppedMessage(explanation:))
        lastMessage = message
        var failure: String?

        do {
            try await client.disableNoSleep()
        } catch {
            // Bez jednoznačné odpovědi zrušení spojení přiměje daemon nastavení vrátit.
            // `.helperFailed`: daemon odpověděl, držení už ukončil a vrácení zkouší dál sám;
            // zrušení spojení by jen shodilo úsporný režim.
            if case HelperClientError.helperFailed = error {} else { resetConnection(sparing: .neverSleep) }
            let text = String(localized: "Vypnutí režimu Nikdy nevypínat se nepodařilo potvrdit: \(error.localizedDescription)")
            lastMessage = message.map { $0 + "\n" + text } ?? text
            failure = text
        }

        if notify, let message {
            Task { [notifier] in await notifier.post(body: message) }
        }
        return failure
    }

    /// Automatické ukončení bdění (AI nepracuje, výpadek sítě): nejdřív B přes daemon, potom A.
    private func performStopAll(notice: String) async {
        guard effectiveKeepAwake else { return }
        let failure = await performTurnOff(explanation: nil, notify: false)
        keepAwakeOn = false
        applyAssertion()
        setExpiry(nil)
        remember()
        lastMessage = failure
        lastNotice = notice
    }

    // MARK: - Úsporný režim (operace)

    private func performLowPowerOn(waitUntil: Date?) async {
        guard !lowPowerOn else {
            cancelPending(.lowPower)
            return
        }
        clearMessages()

        guard await ensureHelperReady(
            unavailableMessage: String(localized: "Pomocný proces není k dispozici, úsporný režim nejde zapnout."),
            retriesConnection: canRetryConnection(pending: lowPowerPendingUntil, waitUntil: waitUntil)
        ) else {
            rememberPending(.lowPower, until: waitUntil)
            return
        }
        cancelPending(.lowPower)
        guard !isShutDown else { return }

        do {
            try await client.enableLowPower()
        } catch {
            if case HelperClientError.helperFailed = error {
                // Daemon odpověděl a nic nezměnil; nejčastěji proto, že Mac úsporný režim nemá.
                await refreshLowPowerStatus(clearStale: false)
            } else {
                // Bez jednoznačné odpovědi mohl daemon zapnutí dokončit; zrušení spojení ho přiměje vše vrátit.
                resetConnection(sparing: .lowPower)
            }
            lastMessage = error.localizedDescription
            return
        }
        guard !isShutDown else { return }   // shutdown() už daemonu řekl, ať režim vypne

        helperModeEpoch += 1
        lowPowerOn = true
        lowPowerSupported = true
        remember()
        syncHeartbeat()
    }

    private func performLowPowerOff(explanation: String?) async {
        cancelPending(.lowPower)
        guard lowPowerOn else { return }
        lowPowerExternalCheck?.cancel()
        lowPowerExternalCheck = nil
        lowPowerOn = false
        syncHeartbeat()
        remember()

        let message = explanation.map { String(localized: "Úsporný režim byl vypnut: \($0).") }
        if let message { lastMessage = message }

        do {
            try await client.disableLowPower()
        } catch {
            // `.helperFailed`: daemon odpověděl, držení už ukončil a vrácení zkouší dál sám;
            // zrušení spojení by jen shodilo režim B. Bez jednoznačné odpovědi se spojení ruší.
            if case HelperClientError.helperFailed = error {} else { resetConnection(sparing: .lowPower) }
            let failure = String(localized: "Vypnutí úsporného režimu se nepodařilo potvrdit: \(error.localizedDescription)")
            lastMessage = message.map { $0 + "\n" + failure } ?? failure
        }
    }

    /// Daemon nebo spojení úsporný režim ukončily; přepínač se vypne a daemon dostane pokyn vše vrátit.
    private func lowPowerDropped(reason: HelperStopReason) {
        guard lowPowerOn else { return }
        let explanation = self.explanation(for: reason)
        Task { [weak self] in
            await self?.submitLowPower(.turnOff(explanation: explanation))
        }
    }

    /// Zeptá se daemonu, jestli Mac úsporný režim má, a při startu uklidí nastavení, které po daemonu
    /// zůstalo. Jen když je daemon už povolený: kvůli dotazu se nikdy neregistruje. Rozhoduje se
    /// podle `heldByHelper`, ne podle systémové hodnoty – tu může mít zapnutou uživatel.
    func refreshLowPowerStatus(clearStale: Bool) async {
        guard usesHelper, !isShutDown, helperState == .ready else { return }
        guard (try? await client.checkedStatus()) != nil else { return }
        guard let status = try? await client.lowPowerStatus() else { return }
        if lowPowerSupported != status.supported { lowPowerSupported = status.supported }
        guard clearStale, !isShutDown, !lowPowerOn, !draining, pendingLowPower == nil, status.heldByHelper else { return }
        do {
            try await client.disableLowPower()
        } catch {
            lastMessage = String(localized: "Úsporný režim zůstal zapnutý z dřívějška a nepodařilo se ho obnovit: \(error.localizedDescription)")
        }
    }

    /// Při otevření panelu: doplní údaj o podpoře, pokud ho ještě nemáme.
    func refreshLowPowerSupportIfNeeded() async {
        guard lowPowerSupported == nil, !draining else { return }
        await refreshLowPowerStatus(clearStale: false)
    }

    /// Pošle daemonu aktuální prahy a zbývající čas.
    private func performResync() async {
        guard neverSleepOn else { return }
        do {
            try await client.enableNoSleep(batteryThresholdPercent: settings.batteryThresholdPercent,
                                           thermalLimit: settings.thermalLimit,
                                           expiresAfter: Self.remainingSeconds(until: expiresAt))
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    private func requestResync() {
        Task { [weak self] in await self?.submit(.resync) }
    }

    /// Automatické vypnutí režimu B (pojistka, daemon, ztráta spojení).
    private func requestAutoOff(explanation: String) {
        guard neverSleepOn else { return }
        Task { [weak self] in
            await self?.submit(.turnOff(explanation: explanation, notify: true))
        }
    }

    // MARK: - Smyčky při zapnutém režimu B

    private func startNeverSleepLoops() {
        stopNeverSleepLoops()
        syncHeartbeat()

        safetyTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.safetyCheckInterval) } catch { return }
                await self?.refreshPower()   // vyhodnotí i prahy
            }
        }

        observeThresholds()
    }

    private func stopNeverSleepLoops() {
        safetyTask?.cancel()
        safetyTask = nil
        resyncTask?.cancel()
        resyncTask = nil
        thresholdObservation += 1   // zneplatní rozpracované sledování nastavení
        syncHeartbeat()
    }

    /// Heartbeat běží, dokud daemon drží aspoň jeden režim (B nebo úsporný). Jeden společný
    /// pro oba; každá polovina odpovědi se vyhodnocuje zvlášť.
    private func syncHeartbeat() {
        let needed = (neverSleepOn || lowPowerOn) && !isShutDown
        guard needed else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            return
        }
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self, client] in
            var failures = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(HelperConstants.heartbeatInterval)) } catch { return }
                guard let epoch = self?.helperModeEpoch else { return }
                do {
                    let beat = try await client.heartbeat()
                    guard !Task.isCancelled, let self else { return }
                    failures = 0
                    // Režim zapnutý až po odeslání dotazu v odpovědi ještě být nemusí.
                    guard epoch == self.helperModeEpoch else { continue }
                    if !beat.active { self.helperStopped(reason: beat.stopReason) }
                    if !beat.lowPowerActive { self.lowPowerDropped(reason: beat.lowPowerStopReason) }
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    failures += 1
                    if failures >= 2 {
                        failures = 0
                        self.requestAutoOff(explanation: self.explanation(for: .clientDisconnected))
                        self.lowPowerDropped(reason: .clientDisconnected)
                    }
                }
            }
        }
    }

    /// Sleduje změny prahů v nastavení, dokud je režim B zapnutý.
    private func observeThresholds() {
        thresholdObservation += 1
        let id = thresholdObservation
        withObservationTracking {
            _ = settings.batteryThresholdPercent
            _ = settings.thermalLimit
        } onChange: { [weak self] in
            Task { @MainActor in self?.thresholdsChanged(observation: id) }
        }
    }

    private func thresholdsChanged(observation id: Int) {
        guard id == thresholdObservation, neverSleepOn else { return }
        observeThresholds()
        // Posuvník mění hodnotu průběžně; daemonu stačí výsledek.
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.neverSleepOn else { return }
            self.evaluateSafety()
            await self.submit(.resync)
        }
    }

    private func helperStopped(reason: HelperStopReason) {
        guard neverSleepOn else { return }
        if reason == .timerExpired {
            timerExpired()
        } else {
            requestAutoOff(explanation: self.explanation(for: reason))
        }
    }

    /// Zánik spojení vrátí v daemonu oba režimy, proto se vypnou oba přepínače.
    private func connectionChanged(_ event: HelperConnectionEvent) {
        let reason: HelperStopReason
        switch event {
        case .interrupted: reason = .helperRestarted
        case .invalidated: reason = .clientDisconnected
        }
        requestAutoOff(explanation: explanation(for: reason))
        lowPowerDropped(reason: reason)
    }

    // MARK: - Pojistky

    private func currentSafetyStop() -> SafetyStopReason? {
        SafetyMonitor.evaluate(
            power: PowerReading(hasBattery: hasBattery, batteryPercent: batteryPercent, isOnBattery: isOnBattery),
            thermalState: thermalState,
            batteryThresholdPercent: settings.batteryThresholdPercent,
            thermalLimit: settings.thermalLimit
        )
    }

    private func evaluateSafety() {
        guard neverSleepOn, let reason = currentSafetyStop() else { return }
        requestAutoOff(explanation: reason.explanation)
    }

    private func installPowerObservers() {
        // Změna zdroje napájení nebo nabití; bez dotazování v pravidelném intervalu.
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch("com.apple.system.powersources", &token, .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshPower() }
        }
        if status == NOTIFY_STATUS_OK { powerNotifyToken = token }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.thermalState = SafetyMonitor.thermalState
                self.evaluateSafety()
            }
        }

        // Úsporný režim podle systému; událost, žádné dotazování.
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemLowPower() }
        }
        refreshSystemLowPower()
    }

    private func refreshSystemLowPower() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        let wasOn = systemLowPowerOn
        if wasOn != enabled { systemLowPowerOn = enabled }
        // Jen pozorovaný přechod zapnuto → vypnuto, zatímco režim držíme: někdo ho vypnul mimo
        // aplikaci. Přepínač se shodí až po krátké prodlevě a nové kontrole (pozdní oznámení po
        // rychlém vypnutí a zapnutí), řádnou cestou přes daemon, aby uvolnil svou značku.
        guard wasOn, !enabled, lowPowerOn, !isShutDown else { return }
        let epoch = helperModeEpoch
        lowPowerExternalCheck?.cancel()
        lowPowerExternalCheck = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !self.isShutDown, self.lowPowerOn, epoch == self.helperModeEpoch,
                  !self.draining, self.pendingLowPower == nil,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            await self.submitLowPower(.turnOff(explanation: String(localized: "někdo ho vypnul v Nastavení systému")))
        }
    }

    private func removePowerObservers() {
        if powerNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(powerNotifyToken)
            powerNotifyToken = NOTIFY_TOKEN_INVALID
        }
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
            self.lowPowerObserver = nil
        }
    }

    // MARK: - Časovač

    /// Konec časovače pro přepínač, který se právě zapíná.
    private func expiryForActivation(_ activation: Activation) -> Date? {
        if effectiveKeepAwake { return expiresAt }      // společný časovač už běží
        switch activation {
        case .restored(let date): return date
        case .fresh: return duration.seconds.map { Date().addingTimeInterval($0) }
        }
    }

    private func setExpiry(_ date: Date?) {
        expiresAt = date
        expiryTask?.cancel()
        expiryTask = nil
        guard let end = date else { return }
        expiryTask = Task { [weak self] in
            // Hodiny se mohou posunout (uspání, seřízení času), proto se zbytek počítá znovu.
            while !Task.isCancelled {
                let remaining = end.timeIntervalSinceNow
                if remaining <= 0 { break }
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            guard !Task.isCancelled, let self, self.expiresAt == end else { return }
            self.timerExpired()
        }
    }

    /// Čas vypršel: vypnou se všechny zapnuté přepínače.
    private func timerExpired() {
        guard effectiveKeepAwake else { return }
        let explanation = self.explanation(for: .timerExpired)
        keepAwakeOn = false
        if neverSleepOn {
            requestAutoOff(explanation: explanation)   // uvolní assertion, zruší časovač a uloží stav
        } else {
            applyAssertion()
            setExpiry(nil)
            remember()
            lastMessage = String(localized: "Nastavený čas vypršel, Mac může znovu usínat.")
        }
    }

    // MARK: - Obnovení po spuštění

    private func restoreRememberedSwitches() async {
        guard !isShutDown, let remembered = settings.switchesToRestore() else {
            if !isShutDown, !effectiveKeepAwake, !lowPowerOn { remember() }   // zapomenout neplatný stav
            return
        }
        // Uživatel mohl přepnout dřív, než obnova doběhla; jeho volba má přednost.
        guard !effectiveKeepAwake, !lowPowerOn else { return }
        // Zapamatovaný konec časovače se předává výslovně, aby se nedostal do ručního zapnutí,
        // které přijde během čekání na daemon.
        let activation = Activation.restored(remembered.expiresAt)
        if remembered.keepAwake { setKeepAwake(true, activation: activation) }
        // Obnova na povolení pomocného procesu nečeká; to dělá jen zapnutí od uživatele.
        if remembered.neverSleep, !isShutDown { await submit(.turnOn(activation, waitUntil: nil)) }
        if remembered.lowPower, !isShutDown, !lowPowerOn { await submitLowPower(.turnOn(waitUntil: nil)) }
    }

    /// Když daemon hlásí, že po něm zůstalo nevrácené nastavení, a režim B nemá být zapnutý,
    /// řekne mu, ať ho vrátí. Samotný dotaz navíc daemon probudí, takže si zbylou značku uklidí
    /// sám při startu. Podle systémové hodnoty SleepDisabled se nerozhoduje: může ji mít
    /// nastavenou někdo jiný a ta se měnit nesmí.
    private func clearStaleNoSleep() async {
        guard usesHelper, !isShutDown, !neverSleepOn, !draining, helperState == .ready else { return }
        guard let status = try? await client.getStatus() else { return }
        guard !isShutDown, !neverSleepOn, !draining, status.heldByHelper else { return }
        do {
            try await client.disableNoSleep()
        } catch {
            lastMessage = String(localized: "Spánek Macu zůstal vypnutý z dřívějška a nepodařilo se ho obnovit: \(error.localizedDescription)")
        }
    }

    // MARK: - Pomocné

    private func applyAssertion() {
        if effectiveKeepAwake {
            if !assertion.acquire(), keepAwakeOn {
                keepAwakeOn = false
                lastMessage = String(localized: "Nepodařilo se zabránit uspání Macu. Zkuste to prosím znovu.")
            }
        } else {
            assertion.release()
        }
    }

    /// Nová akce uživatele: staré hlášení i sdělení zmizí.
    private func clearMessages() {
        lastMessage = nil
        lastNotice = nil
        helperNote = nil
    }

    private func remember() {
        settings.rememberSwitches(keepAwake: keepAwakeOn, neverSleep: neverSleepOn,
                                  lowPower: lowPowerOn, expiresAt: expiresAt)
    }

    /// Převede stav registrace na stav pro panel. `.notFound` hlásí systém i u služby, která jen
    /// ještě není zaregistrovaná (čerstvá instalace); bere se proto jako „neregistrováno" a karta
    /// nabídne běžné povolení. Výjimkou je balíček, ve kterém popis služby opravdu chybí.
    /// `keepsUnavailable`: pouhé zjištění „povoleno" nepřepíše chybu, kterou ohlásil sám daemon
    /// (jiná verze, spojení); tu smaže až úspěšné ověření nebo nová registrace.
    private func apply(registration: HelperRegistration, keepsUnavailable: Bool = true) {
        let state: HelperState
        switch registration {
        case .notRegistered:
            state = .notRegistered
        case .requiresApproval:
            state = .requiresApproval
        case .enabled:
            if keepsUnavailable, case .unavailable = helperState { return }
            state = .ready
        case .notFound:
            state = Self.daemonPlistInBundle ? .notRegistered : .missingFromBundle
        }
        if helperState != state { helperState = state }
    }

    private static var diagnosticMessage: String {
        String(localized: "Zkušební spuštění pomocný proces nepoužívá, přepínač proto nejde zapnout.")
    }

    private func beginBusy() {
        busyCount += 1
        isBusy = true
    }

    private func endBusy() {
        busyCount = max(0, busyCount - 1)
        isBusy = busyCount > 0
    }

    private static func remainingSeconds(until date: Date?) -> Double {
        guard let date else { return 0 }   // 0 = bez limitu
        return max(1, date.timeIntervalSinceNow)
    }

    /// Česká část věty za dvojtečkou podle důvodu, který ohlásil daemon.
    private func explanation(for reason: HelperStopReason) -> String {
        switch reason {
        case .lowBattery: SafetyStopReason.lowBattery(percent: batteryPercent ?? 0, threshold: settings.batteryThresholdPercent).explanation
        case .thermal: String(localized: "Mac se příliš zahřívá")
        case .timerExpired: String(localized: "vypršel nastavený čas")
        case .heartbeatTimeout: String(localized: "pomocný proces ztratil spojení s aplikací")
        case .clientDisconnected: String(localized: "spojení s pomocným procesem se přerušilo")
        case .helperRestarted: String(localized: "pomocný proces byl restartován")
        case .requestedByApp, .none: String(localized: "ukončil ho pomocný proces")
        }
    }
}
