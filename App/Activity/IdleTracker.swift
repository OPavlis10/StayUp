import Foundation

/// Sleduje, jak dlouho sledované procesy nepřetržitě nepracují. Čistá hodnota bez hodin a bez systémových
/// volání: čas dostává zvenku (`ActivityClock.uptime()`), takže se dá celá otestovat.
///
/// Pravidla:
/// - „pracuje“ (`true`) počítadlo nečinnosti vynuluje,
/// - „nepracuje“ (`false`) k němu přičte dobu od předchozího vzorku,
/// - „nevím“ (`nil`, první vzorek nebo selhání čtení) nic nepřičte ani nevynuluje,
/// - po `start` je počítadlo na nule, takže i když sledované procesy od zapnutí přepínače **nikdy**
///   nepracovaly, vyprší až po celé době `requiredIdle` – stejné pravidlo slouží jako ochranná lhůta,
/// - jeden krok se započítá nejvýš jako `maxStep`. Hodiny `ActivityClock` během spánku Macu stojí,
///   takže spánek se nepočítá; strop navíc kryje zaseknuté vzorkování a jiné hodiny
///   (čas, kdy se nikdo nedíval, není doložená nečinnost).
struct IdleTracker: Sendable, Equatable {
    /// Povolený rozsah nastavení v minutách.
    static let minutesRange: ClosedRange<Int> = 2...120
    static let defaultMinutes = 10
    /// Výchozí strop jednoho kroku; počítá se vzorkováním po 15–20 s.
    static let defaultMaxStep: TimeInterval = 60

    /// Jak dlouho musí nečinnost trvat (sekundy, vždy v rozsahu `minutesRange`).
    private(set) var requiredIdle: TimeInterval
    let maxStep: TimeInterval

    /// Dosud nasbíraná nepřetržitá nečinnost v sekundách.
    private(set) var idleDuration: TimeInterval = 0
    /// Jestli byla od `start` aspoň jednou vidět práce (jen pro zobrazení, na vypršení nemá vliv).
    private(set) var hasSeenWork = false
    private var lastUptime: TimeInterval?

    init(minutes: Int = IdleTracker.defaultMinutes, maxStep: TimeInterval = IdleTracker.defaultMaxStep) {
        self.requiredIdle = Self.seconds(forMinutes: minutes)
        self.maxStep = max(1, maxStep)
    }

    /// Nečinnost trvá aspoň `requiredIdle`: přepínače se mají vypnout.
    var hasExpired: Bool { idleDuration >= requiredIdle }

    /// Kolik sekund nečinnosti ještě zbývá do vypršení.
    var remaining: TimeInterval { max(0, requiredIdle - idleDuration) }

    /// Zbývající čas zaokrouhlený nahoru na celé minuty – pro zobrazení (mění se nejvýš jednou za minutu).
    var remainingMinutes: Int { Int((remaining / 60).rounded(.up)) }

    /// Začátek sledování (zapnutí přepínače nebo automatického režimu). Vynuluje všechno.
    mutating func start(at uptime: TimeInterval) {
        idleDuration = 0
        hasSeenWork = false
        lastUptime = uptime
    }

    /// Změna nastavení za běhu. Nasbíraná nečinnost zůstává.
    mutating func setMinutes(_ minutes: Int) {
        requiredIdle = Self.seconds(forMinutes: minutes)
    }

    /// Zapíše jeden vzorek. Vrací `hasExpired`.
    /// Bez předchozího `start` se první volání chová jako `start` v čase vzorku.
    @discardableResult
    mutating func record(isWorking: Bool?, at uptime: TimeInterval) -> Bool {
        let step: TimeInterval
        if let lastUptime {
            // Záporný krok (jiné hodiny, chyba volajícího) se bere jako nula.
            step = min(max(0, uptime - lastUptime), maxStep)
        } else {
            step = 0
        }
        lastUptime = uptime

        switch isWorking {
        case .some(true):
            idleDuration = 0
            hasSeenWork = true
        case .some(false):
            idleDuration += step
        case .none:
            break
        }
        return hasExpired
    }

    @discardableResult
    mutating func record(_ sample: ActivitySample) -> Bool {
        record(isWorking: sample.isWorking, at: sample.uptime)
    }

    private static func seconds(forMinutes minutes: Int) -> TimeInterval {
        TimeInterval(min(max(minutes, minutesRange.lowerBound), minutesRange.upperBound) * 60)
    }
}
