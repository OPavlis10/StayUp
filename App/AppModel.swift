import Foundation
import Observation

/// Poslední známé hodnoty přehledu systému a krátká historie pro grafy.
/// Každá metrika je samostatná vlastnost, aby se překreslil jen řádek, kterého se změna týká.
@MainActor
@Observable
final class MetricsStore {
    /// Počet bodů historie (při otevřeném panelu zhruba jedna minuta).
    static let historyCapacity = 60

    private(set) var cpu: CPUMetrics?
    /// Celé procento pro ikonu v liště. Zapisuje se záměrně zřídka, viz `updateMenuBar`.
    private(set) var menuBarCPUPercent: Int?
    /// Paměť už jako hotové texty: řádek se překreslí, jen když se změní něco viditelného.
    private(set) var memory: MemoryDisplay?
    private(set) var disk: DiskMetrics?
    /// Využití zaokrouhlené na celá procenta (tolik je vidět).
    private(set) var gpu: GPUMetrics?
    private(set) var network: NetworkMetrics?
    /// „Kdo žere energii": hotové řádky; `nil`, dokud po otevření panelu není první měření.
    private(set) var topProcesses: TopProcessesDisplay?
    /// „Příkon a výdrž" jako jeden hotový řádek; `nil` = údaj není (nebo Mac nemá baterii).
    private(set) var powerLine: String?

    /// Celkové využití CPU 0...1.
    private(set) var cpuHistory: [Double] = []
    /// Bajty za sekundu.
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []

    @ObservationIgnored private var lastFullSample: Date?
    @ObservationIgnored private var menuBarUpdatedAt: Date?

    /// Při otevřeném panelu se číslo v liště obnovuje nejvýš jednou za tuto dobu (živou hodnotu ukazuje panel).
    /// Původně 60 s; jedna změna stála v měření 75–130 ms CPU, tedy přes 0,1 % jádra v průměru.
    /// Po zavření panelu se číslo srovná podle pravidel pro zavřený panel (viz `updateMenuBar`).
    private static let menuBarOpenInterval: TimeInterval = 300
    /// Při zavřeném panelu se změna o jediný bod propíše až po této době.
    private static let menuBarSettleInterval: TimeInterval = 12

    /// `menuBarShowsCPU` = lišta ukazuje i číslo. S volbou „V liště jen ikona" se číslo pro lištu
    /// vůbec nezapisuje (jen se jednou vyprázdní), takže položka v liště nemá co překreslovat.
    func apply(_ snapshot: SystemSnapshot, detail: SampleDetail, menuBarShowsCPU: Bool = true) {
        if cpu != snapshot.cpu { cpu = snapshot.cpu }
        if menuBarShowsCPU {
            updateMenuBar(snapshot.cpu.map { Int(($0.total * 100).rounded()) },
                          at: snapshot.timestamp, panelOpen: detail == .full)
        } else if menuBarCPUPercent != nil {
            // Po vypnutí volby se tak hned ukáže čerstvá hodnota, ne ta z doby před zapnutím.
            menuBarCPUPercent = nil
            menuBarUpdatedAt = nil
        }

        // Úsporný vzorek ostatní údaje nenese; panel si nechává poslední plné hodnoty.
        guard detail == .full else { return }

        let memoryDisplay = snapshot.memory.map(MemoryDisplay.init)
        if memory != memoryDisplay { memory = memoryDisplay }
        if disk != snapshot.disk { disk = snapshot.disk }
        let gpuShown = snapshot.gpu.map {
            GPUMetrics(utilization: $0.utilization.isFinite ? ($0.utilization * 100).rounded() / 100 : 0, name: $0.name)
        }
        if gpu != gpuShown { gpu = gpuShown }
        if network != snapshot.network { network = snapshot.network }

        // Po delší pauze (panel byl zavřený) by graf spojil nesouvisející body.
        if let last = lastFullSample, snapshot.timestamp.timeIntervalSince(last) > 5 {
            cpuHistory.removeAll(keepingCapacity: true)
            downloadHistory.removeAll(keepingCapacity: true)
            uploadHistory.removeAll(keepingCapacity: true)
        }
        lastFullSample = snapshot.timestamp

        if let cpu = snapshot.cpu { Self.append(cpu.total, to: &cpuHistory) }
        if let network = snapshot.network {
            Self.append(network.downloadBytesPerSecond, to: &downloadHistory)
            Self.append(network.uploadBytesPerSecond, to: &uploadHistory)
        }
    }

    /// Vzorkování pro lištu se zastavilo („V liště jen ikona"): staré číslo se zahodí, aby se po
    /// vypnutí volby ukázala až čerstvá hodnota.
    func clearMenuBar() {
        if menuBarCPUPercent != nil { menuBarCPUPercent = nil }
        menuBarUpdatedAt = nil
    }

    func apply(processes snapshot: TopProcessesSnapshot?) {
        let display = snapshot.map(TopProcessesDisplay.init)
        if topProcesses != display { topProcesses = display }
    }

    func apply(power metrics: PowerDrawMetrics?) {
        let line = metrics.flatMap { PowerDrawDisplay($0).summaryLine }
        if powerLine != line { powerLine = line }
    }

    /// Každá změna ikony v liště je drahá: AppKit při ní znovu snímá položku pro světlý i tmavý vzhled
    /// a SwiftUI ji kvůli tomu dvakrát překreslí (desítky ms CPU na jednu změnu). Proto se číslo
    /// nepřepisuje s každým vzorkem. Při otevřeném panelu ho drží až `menuBarOpenInterval`,
    /// při zavřeném se hned propíše změna aspoň o dva body, menší až po `menuBarSettleInterval`.
    private func updateMenuBar(_ percent: Int?, at now: Date, panelOpen: Bool) {
        guard menuBarCPUPercent != percent else { return }
        if let shown = menuBarCPUPercent, let percent, let last = menuBarUpdatedAt {
            let elapsed = now.timeIntervalSince(last)
            // Záporný rozdíl = posun hodin; pak se nečeká.
            if elapsed >= 0 {
                if panelOpen {
                    guard elapsed >= Self.menuBarOpenInterval else { return }
                } else if abs(percent - shown) < 2 {
                    guard elapsed >= Self.menuBarSettleInterval else { return }
                }
            }
        }
        menuBarCPUPercent = percent
        menuBarUpdatedAt = now
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value.isFinite ? max(value, 0) : 0)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
    }
}

/// Kořen aplikace: vlastní nastavení, řízení spánku, sběr metrik a jedinou vzorkovací smyčku.
/// Navíc spouští a zastavuje sledování AI procesů a hlídání sítě podle toho, co je zapnuté.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let sleep: SleepController
    let metrics = MetricsStore()
    let location = LocationPermission()
    /// „Bdít, jen dokud AI pracuje".
    let aiActivity = AIActivityMonitor()
    /// Hlídání sítě; běží jen při zapnutém bdění.
    let network = NetworkWatch()

    private(set) var isPanelOpen = false

    @ObservationIgnored private let collector = MetricsCollector()
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var lastSampleAt: ContinuousClock.Instant?
    /// Kolik prvních vzorků po spuštění se bere v krátkém intervalu (viz `sampleOnce`).
    @ObservationIgnored private var warmupSamples = 2
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    /// Smyčka neběží, protože lišta ukazuje jen ikonu a panel je zavřený.
    @ObservationIgnored private var samplingPaused = false

    @ObservationIgnored private let energy = EnergyCollector()
    /// Pořadí vzorku od otevření panelu; podle něj se řídí řidší měření (procesy, příkon).
    @ObservationIgnored private var openTick = 0
    /// Přepínače spánku při posledním vyhodnocení (kvůli novému odpočtu nečinnosti AI).
    @ObservationIgnored private var lastSwitches = (keepAwake: false, neverSleep: false)
    /// Nečinnost AI vypršela a bdění se právě vypíná; do vypnutí se sledování znovu nespouští.
    @ObservationIgnored private var aiStopInProgress = false

    /// Žebříček procesů každý pátý a příkon každý desátý sekundový vzorek otevřeného panelu.
    /// Při 3 s a 5 s se panel držel těsně u hranice 1 % CPU; takhle má rezervu.
    private static let processStride = 5
    private static let powerStride = 10
    private static let processLimit = 3

    /// Interval vzorkování při otevřeném a zavřeném panelu.
    private static let openInterval: Duration = .seconds(1)
    private static let closedInterval: Duration = .seconds(4)
    /// Kratší rozestup by dal nesmyslné průměry CPU a sítě.
    private static let minimumGap: Duration = .milliseconds(500)

    init() {
        // Zkušební spuštění (testy, náhledy) má vlastní prázdné nastavení a pomocný proces nepoužívá.
        let settings = AppSettings(defaults: LaunchMode.makeDefaults(),
                                   managesLoginItem: !LaunchMode.isDiagnostic)
        self.settings = settings
        self.sleep = SleepController(settings: settings, usesHelper: !LaunchMode.isDiagnostic)
    }

    // MARK: - Životní cyklus

    func start() {
        guard !started else { return }
        started = true
        sleep.start()
        aiActivity.onExpired = { [weak self] minutes in self?.aiIdleExpired(minutes: minutes) }
        network.onEvent = { [weak self] event in self?.networkEvent(event) }
        observeConditions()
        observeMenuBarMode()
        syncWatchers()
        // Výchozí stav čítačů vznikl těsně před tímto okamžikem; první vzorek proto musí
        // počkat aspoň `minimumGap`, jinak by se počítal z téměř nulového okna.
        lastSampleAt = ContinuousClock().now
        restartSampling()
    }

    /// Volá se z `applicationWillTerminate`; vrátí spánek Macu do původního stavu.
    func shutdown() {
        guard !stopped else { return }
        stopped = true
        samplingTask?.cancel()
        samplingTask = nil
        aiActivity.stop()
        network.stop()
        sleep.shutdown()
    }

    // MARK: - Panel

    func setPanelOpen(_ open: Bool) {
        guard open != isPanelOpen, !stopped else { return }
        isPanelOpen = open
        // Nová smyčka hned přejde na správný interval (stará by dospala ten svůj).
        openTick = 0
        restartSampling()
        guard open else {
            metrics.apply(processes: nil)   // po dalším otevření se nejdřív ukáže „Měřím…", ne starý žebříček
            Task { [energy] in await energy.panelClosed() }
            return
        }
        Task { [weak self, energy, sleep, location] in
            location.refresh()
            await energy.panelOpened()
            let power = await energy.samplePower()
            if let self, self.isPanelOpen { self.metrics.apply(power: power) }
            await sleep.refreshPower()
            await sleep.refreshHelperState()
            await sleep.refreshLowPowerSupportIfNeeded()
        }
    }

    // MARK: - Sledování AI a sítě

    /// Jedno sledování pro všechno, co rozhoduje o běhu obou hlídačů. Po každé změně se nasadí znovu.
    private func observeConditions() {
        withObservationTracking {
            _ = sleep.keepAwakeOn
            _ = sleep.neverSleepOn
            _ = settings.autoOffWhenAIIdle
            _ = settings.aiProcessPatterns
            _ = settings.aiCPUThresholdPercent
            _ = settings.aiIdleMinutes
            _ = settings.networkWatchEnabled
            _ = settings.networkEndAfterEnabled
            _ = settings.networkEndAfterMinutes
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.observeConditions()
                self.syncWatchers()
            }
        }
    }

    private func syncWatchers() {
        guard !stopped else { return }
        syncAIActivity()
        syncNetworkWatch()
        lastSwitches = (sleep.keepAwakeOn, sleep.neverSleepOn)
    }

    /// Sledování AI běží jen při zapnutém přepínači spánku a zapnuté volbě; jinak neexistuje ani úloha.
    private func syncAIActivity() {
        if !sleep.effectiveKeepAwake { aiStopInProgress = false }
        let wanted = settings.autoOffWhenAIIdle && sleep.effectiveKeepAwake && !aiStopInProgress
        guard wanted else {
            aiActivity.stop()
            return
        }
        if !aiActivity.isRunning {
            aiActivity.start(patterns: settings.aiProcessPatterns,
                             thresholdPercent: settings.aiCPUThresholdPercent,
                             minutes: settings.aiIdleMinutes)
            return
        }
        aiActivity.update(patterns: settings.aiProcessPatterns,
                          thresholdPercent: settings.aiCPUThresholdPercent,
                          minutes: settings.aiIdleMinutes)
        // Uživatel zapnul další přepínač: dává najevo, že Mac má běžet dál.
        let newlyOn = (sleep.keepAwakeOn && !lastSwitches.keepAwake) || (sleep.neverSleepOn && !lastSwitches.neverSleep)
        if newlyOn { aiActivity.restartCountdown() }
    }

    private func aiIdleExpired(minutes: Int) {
        guard !stopped else { return }
        aiStopInProgress = true
        let notice = String(localized: "Stay Up vypnul bdění: AI \(minutes)\u{00A0}min nepracuje.")
        Task { [weak self, sleep] in
            await sleep.stopKeepAwake(notice: notice)
            // Zůstal-li z jakéhokoli důvodu některý přepínač zapnutý, sledování se obnoví s novým odpočtem.
            guard let self, !self.stopped, self.aiStopInProgress, sleep.effectiveKeepAwake else { return }
            self.aiStopInProgress = false
            self.syncWatchers()
        }
    }

    /// Hlídání sítě běží jen při zapnutém bdění; každé zapnutí bdění začíná s čistým stavem.
    private func syncNetworkWatch() {
        let wanted = sleep.effectiveKeepAwake && (settings.networkWatchEnabled || settings.networkEndAfterEnabled)
        network.endAfter = OutageTracker.endAfter(enabled: settings.networkEndAfterEnabled,
                                                  minutes: settings.networkEndAfterMinutes)
        if wanted { network.start() } else { network.stop() }
    }

    private func networkEvent(_ event: OutageTracker.Event) {
        guard !stopped, sleep.effectiveKeepAwake else { return }
        let notifies = settings.networkWatchEnabled
        switch event {
        case .lost:
            if notifies { Task { [notifier = sleep.notifier] in await notifier.postNetworkLost() } }
        case .restored:
            if notifies { Task { [notifier = sleep.notifier] in await notifier.postNetworkRestored() } }
        case .endKeepAwakeDue:
            let minutes = settings.networkEndAfterMinutes
            let notice = String(localized: "Stay Up vypnul bdění: Mac je \(minutes)\u{00A0}min bez připojení.")
            Task { [sleep] in
                await sleep.stopKeepAwake(notice: notice)
                if notifies { await sleep.notifier.postKeepAwakeEndedNoNetwork(minutes: minutes) }
            }
        }
    }

    // MARK: - Vzorkování

    /// Volba „V liště jen ikona" rozhoduje, jestli smyčka při zavřeném panelu vůbec běží.
    private func observeMenuBarMode() {
        withObservationTracking {
            _ = settings.menuBarIconOnly
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.observeMenuBarMode()
                self.restartSampling()
            }
        }
    }

    private func restartSampling() {
        samplingTask?.cancel()
        samplingTask = nil
        guard started, !stopped else { return }
        // Zavřený panel a lišta bez čísla: vzorek by nikdo neviděl, smyčka proto neexistuje.
        guard isPanelOpen || !settings.menuBarIconOnly else {
            samplingPaused = true
            metrics.clearMenuBar()
            return
        }
        if samplingPaused {
            samplingPaused = false
            // První vzorek po pauze je průměr za celou pauzu; hned ho nahradí další.
            if !isPanelOpen { warmupSamples = max(warmupSamples, 1) }
        }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.sampleOnce() else { return }
                do {
                    try await Task.sleep(for: wait.duration, tolerance: wait.tolerance)
                } catch {
                    return
                }
            }
        }
    }

    /// Vezme jeden vzorek a vrátí, jak dlouho čekat na další.
    private func sampleOnce() async -> (duration: Duration, tolerance: Duration) {
        let clock = ContinuousClock()
        if let last = lastSampleAt {
            let elapsed = clock.now - last
            if elapsed < Self.minimumGap {
                return (Self.minimumGap - elapsed, .milliseconds(20))
            }
        }
        let detail: SampleDetail = isPanelOpen ? .full : .menuBarOnly
        lastSampleAt = clock.now
        let snapshot = await collector.sample(detail: detail)
        guard !Task.isCancelled else { return (Self.minimumGap, .milliseconds(20)) }
        metrics.apply(snapshot, detail: detail, menuBarShowsCPU: !settings.menuBarIconOnly)
        if isPanelOpen {
            await sampleEnergy()
            return (Self.openInterval, .milliseconds(100))
        }
        if warmupSamples > 0 {
            // Po spuštění je první hodnota zkreslená startem aplikace; rychle ji nahradíme.
            warmupSamples -= 1
            return (Self.openInterval, .milliseconds(100))
        }
        return (Self.closedInterval, .seconds(1))
    }

    /// Žebříček procesů a příkon: jen při otevřeném panelu, ve stejné smyčce, řidčeji než ostatní údaje.
    private func sampleEnergy() async {
        openTick += 1
        let tick = openTick
        if tick % Self.processStride == 0 {
            let snapshot = await energy.sampleProcesses(limit: Self.processLimit)
            // První volání po otevření může vrátit `nil` (ještě není s čím porovnat); starý údaj zůstane.
            if let snapshot, isPanelOpen, !Task.isCancelled { metrics.apply(processes: snapshot) }
        }
        if tick % Self.powerStride == 0 {
            let power = await energy.samplePower()
            if isPanelOpen, !Task.isCancelled { metrics.apply(power: power) }
        }
    }
}
