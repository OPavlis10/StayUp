import AppKit
import Network
import Observation

/// Hlídání sítě: pasivně sleduje, jestli má Mac použitelnou síťovou cestu, a přes
/// `OutageTracker` z toho dělá události „ztraceno / zpět / ukončit bdění".
///
/// Cena: NWPathMonitor je řízený událostmi, nic se neptá v intervalu a neposílá žádná data.
/// Při stabilní síti hlídání nestojí nic (0 probuzení). Jediný časovač běží jen během
/// výpadku a je to jedno probuzení na konci ochranné doby, případně jedno na konci doby
/// pro ukončení bdění. Zveřejněné vlastnosti se mění jen při skutečné změně stavu.
///
/// Omezení: `satisfied` = systém má trasu, ne ověřený internet (viz `NetworkPathState`).
/// Výpadek „za routerem" nebo přihlašovací stránku Wi-Fi tak hlídání nepozná.
@MainActor
@Observable
final class NetworkWatch {
    /// Poslední známá cesta; `nil`, dokud hlídání neběží nebo ještě nic nepřišlo.
    private(set) var path: NetworkPathState?
    /// Fáze výpadku; mění se jen při přechodu, ne v čase.
    private(set) var phase: OutageTracker.Phase = .unknown
    /// Kdy připojení zmizelo (pro zobrazení „bez připojení od 14:32"); `nil` mimo `.lost`.
    private(set) var outageStartedAt: Date?
    private(set) var isRunning = false

    /// Události pro volajícího (oznámení, ukončení bdění). Volá se na hlavním vlákně.
    @ObservationIgnored var onEvent: (@MainActor (OutageTracker.Event) -> Void)?

    /// Ochranná doba proti zakolísání a probuzení.
    var gracePeriod: Duration {
        get { tracker.gracePeriod }
        set {
            guard newValue != tracker.gracePeriod else { return }
            tracker.gracePeriod = newValue
            reevaluate()
        }
    }

    /// Po jak dlouhém výpadku ohlásit `.endKeepAwakeDue`; `nil` = vypnuto.
    /// Hodnotu z nastavení vyrobí `OutageTracker.endAfter(enabled:minutes:)`.
    var endAfter: Duration? {
        get { tracker.endAfter }
        set {
            guard newValue != tracker.endAfter else { return }
            tracker.endAfter = newValue
            reevaluate()
        }
    }

    @ObservationIgnored private var tracker: OutageTracker
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// Hodiny, které při spánku Macu stojí.
    @ObservationIgnored private let clock = SuspendingClock()
    @ObservationIgnored private let origin: SuspendingClock.Instant
    @ObservationIgnored private let queue = DispatchQueue(label: "cz.stayup.StayUp.network-watch", qos: .utility)

    init(gracePeriod: Duration = OutageTracker.defaultGracePeriod, endAfter: Duration? = nil) {
        tracker = OutageTracker(gracePeriod: gracePeriod, endAfter: endAfter)
        origin = SuspendingClock().now
    }

    // MARK: - Životní cyklus

    /// Začne hlídat. Opakované volání nic nedělá. První stav cesty přijde během milisekund.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPathState.self,
                                                             bufferingPolicy: .bufferingNewest(8))
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            continuation.yield(NetworkPathState(path))
        }
        monitor.start(queue: queue)
        self.monitor = monitor

        // Jeden odběratel = zachované pořadí změn.
        consumeTask = Task { [weak self] in
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                self.receive(state)
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    /// Přestane hlídat a zapomene stav. Po zastavení už žádná událost nepřijde.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor?.cancel()   // zruší i handler, a tím ukončí proud
        monitor?.pathUpdateHandler = nil
        monitor = nil
        consumeTask?.cancel()
        consumeTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        tracker.reset()
        path = nil
        publishPhase()
    }

    /// Začne výpadek počítat od teď. Volat, když se bdění zapne při už běžícím hlídání
    /// (např. hlídání běželo jen kvůli zobrazení v panelu), aby se čerstvě zapnuté bdění
    /// hned neukončilo kvůli výpadku, který začal dávno.
    func rearm() {
        guard isRunning else { return }
        tracker.rearm(now: now)
        publishPhase()
        scheduleDeadline()
    }

    /// Jak dlouho trvá ohlášený výpadek (bez doby spánku Macu); `nil`, když žádný není.
    func outageDuration() -> Duration? {
        tracker.outageDuration(now: now)
    }

    // MARK: - Vnitřek

    private var now: Duration { clock.now - origin }

    private func receive(_ state: NetworkPathState) {
        guard isRunning else { return }
        if path != state { path = state }
        deliver(tracker.pathChanged(online: state.isUsable, now: now))
    }

    private func didWake() {
        guard isRunning else { return }
        tracker.noteWake(now: now)
        publishPhase()
        scheduleDeadline()
    }

    private func reevaluate() {
        guard isRunning else { return }
        deliver(tracker.tick(now: now))
    }

    private func deliver(_ events: [OutageTracker.Event]) {
        publishPhase()
        scheduleDeadline()
        for event in events {
            guard isRunning else { return }   // obsluha události mohla hlídání zastavit
            onEvent?(event)
        }
    }

    private func publishPhase() {
        if phase != tracker.phase { phase = tracker.phase }
        if let outage = tracker.outageDuration(now: now) {
            if outageStartedAt == nil {
                let seconds = Double(outage.components.seconds)
                outageStartedAt = Date().addingTimeInterval(-seconds)
            }
        } else if outageStartedAt != nil {
            outageStartedAt = nil
        }
    }

    /// Naplánuje jediné probuzení na příští termín sledovače; bez termínu žádný časovač neběží.
    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard isRunning, let deadline = tracker.nextDeadline else { return }
        let instant = origin.advanced(by: deadline)
        deadlineTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(until: instant, tolerance: .seconds(1))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.deadlineTask = nil
            self.reevaluate()
        }
    }
}
