/// Čistá logika výpadku připojení: žádné hodiny, žádné časovače, žádný systém.
///
/// Čas se předává zvenku jako `now` = doba běhu na hodinách, které se při uspání Macu
/// zastaví (SuspendingClock). Díky tomu se spánek do ochranné doby ani do délky výpadku
/// nepočítá. Volající navíc při probuzení volá `noteWake`, protože těsně po probuzení
/// síť chvíli není a to výpadek není.
///
/// Průběh: online → (cesta spadne) čeká se `gracePeriod` → `.lost` → případně
/// `.endKeepAwakeDue` po `endAfter` → (cesta je zpět) `.restored`, právě jednou.
/// Krátké zakolísání kratší než `gracePeriod` neohlásí nic.
struct OutageTracker: Sendable, Equatable {
    static let defaultGracePeriod: Duration = .seconds(60)
    /// Rozsah a výchozí hodnota nastavení „ukončit bdění po N minutách bez připojení".
    static let endAfterMinutesRange: ClosedRange<Int> = 1...120
    static let defaultEndAfterMinutes = 10

    enum Event: Sendable, Equatable {
        /// Připojení chybí déle než ochrannou dobu.
        case lost
        /// Připojení je zpět po ohlášeném výpadku; `outage` = jak dlouho chybělo.
        case restored(outage: Duration)
        /// Výpadek trvá aspoň `endAfter`; volající má ukončit bdění. Jednou za výpadek.
        case endKeepAwakeDue(outage: Duration)
    }

    enum Phase: Sendable, Equatable {
        /// Zatím nepřišel žádný stav cesty.
        case unknown
        case online
        /// Cesta není, ale ochranná doba ještě neuplynula (možná jen zakolísání).
        case pending
        /// Výpadek byl ohlášen.
        case lost
    }

    /// Jak dlouho musí připojení chybět, než se ohlásí výpadek.
    var gracePeriod: Duration
    /// Po jak dlouhém výpadku ohlásit `.endKeepAwakeDue`; `nil` = funkce vypnutá.
    var endAfter: Duration?

    private(set) var phase: Phase = .unknown
    /// Odkdy se výpadek počítá (po probuzení v ochranné době se posouvá).
    private var offlineSince: Duration?
    private var endReported = false
    /// Po probuzení během výpadku se bdění neukončí dřív než za další ochrannou dobu.
    private var endNotBefore: Duration?

    init(gracePeriod: Duration = OutageTracker.defaultGracePeriod, endAfter: Duration? = nil) {
        self.gracePeriod = gracePeriod
        self.endAfter = endAfter
    }

    /// `endAfter` z minut v nastavení; hodnota se ořízne do `endAfterMinutesRange`.
    static func endAfter(enabled: Bool, minutes: Int) -> Duration? {
        guard enabled else { return nil }
        let clamped = min(max(minutes, endAfterMinutesRange.lowerBound), endAfterMinutesRange.upperBound)
        return .seconds(clamped * 60)
    }

    /// Nový stav cesty. `online` = cesta je použitelná.
    mutating func pathChanged(online: Bool, now: Duration) -> [Event] {
        guard online else {
            if offlineSince == nil {
                offlineSince = now
                phase = .pending
                endReported = false
                endNotBefore = nil
            }
            return evaluate(now: now)
        }
        var events: [Event] = []
        if phase == .lost, let since = offlineSince {
            events.append(.restored(outage: max(now - since, .zero)))
        }
        phase = .online
        offlineSince = nil
        endReported = false
        endNotBefore = nil
        return events
    }

    /// Volá se, když nastal čas z `nextDeadline` (klidně i častěji; je to idempotentní).
    mutating func tick(now: Duration) -> [Event] {
        evaluate(now: now)
    }

    /// Mac se právě probudil. Neohlášený výpadek se začne počítat znovu od teď;
    /// ohlášený zůstává, jen se ukončení bdění odloží aspoň o ochrannou dobu.
    mutating func noteWake(now: Duration) {
        switch phase {
        case .pending:
            offlineSince = now
        case .lost:
            endNotBefore = max(endNotBefore ?? now, now + gracePeriod)
        case .unknown, .online:
            break
        }
    }

    /// Začne počítat od nuly, jako by cesta spadla až teď (např. uživatel zapnul bdění
    /// ve chvíli, kdy už připojení dlouho není). Nic neohlásí.
    mutating func rearm(now: Duration) {
        guard offlineSince != nil else { return }
        offlineSince = now
        phase = .pending
        endReported = false
        endNotBefore = nil
    }

    /// Zapomene všechno (zastavení hlídání).
    mutating func reset() {
        phase = .unknown
        offlineSince = nil
        endReported = false
        endNotBefore = nil
    }

    /// Jak dlouho připojení chybí; `nil`, když je připojeno nebo se stav neví.
    func offlineDuration(now: Duration) -> Duration? {
        offlineSince.map { max(now - $0, .zero) }
    }

    /// Délka OHLÁŠENÉHO výpadku; `nil` mimo fázi `.lost`.
    func outageDuration(now: Duration) -> Duration? {
        phase == .lost ? offlineDuration(now: now) : nil
    }

    /// Kdy má volající příště zavolat `tick`; `nil` = není na co čekat (žádný časovač).
    var nextDeadline: Duration? {
        guard let since = offlineSince else { return nil }
        switch phase {
        case .pending:
            return since + gracePeriod
        case .lost:
            guard !endReported, let endAfter else { return nil }
            return max(since + endAfter, endNotBefore ?? since)
        case .unknown, .online:
            return nil
        }
    }

    private mutating func evaluate(now: Duration) -> [Event] {
        guard let since = offlineSince else { return [] }
        var events: [Event] = []
        if phase == .pending, now - since >= gracePeriod {
            phase = .lost
            events.append(.lost)
        }
        if phase == .lost, !endReported, let endAfter,
           now - since >= endAfter, now >= (endNotBefore ?? since) {
            endReported = true
            events.append(.endKeepAwakeDue(outage: now - since))
        }
        return events
    }
}
