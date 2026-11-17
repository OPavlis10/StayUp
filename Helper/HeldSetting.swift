import Foundation

// MARK: - Hodnoty úsporného režimu

/// Zdroj napájení, pro který pmset vede vlastní sadu nastavení.
enum PowerProfile: String, Codable, CaseIterable, Sendable {
    case battery
    case ac
    case ups

    /// Přepínač pmset pro zápis jen do této sady.
    var pmsetFlag: String {
        switch self {
        case .battery: "-b"
        case .ac: "-c"
        case .ups: "-u"
        }
    }

    /// Název oddílu ve výstupu `pmset -g custom` (bez dvojtečky).
    var pmsetSectionTitle: String {
        switch self {
        case .battery: "Battery Power"
        case .ac: "AC Power"
        case .ups: "UPS Power"
        }
    }
}

/// Hodnota `lowpowermode` zvlášť pro každý zdroj napájení. `nil` = Mac pro tento zdroj hodnotu
/// nemá (stolní Mac nemá baterii, UPS bývá jen výjimečně).
struct LowPowerState: Codable, Equatable, Sendable {
    var battery: Bool?
    var ac: Bool?
    var ups: Bool?

    subscript(profile: PowerProfile) -> Bool? {
        get {
            switch profile {
            case .battery: battery
            case .ac: ac
            case .ups: ups
            }
        }
        set {
            switch profile {
            case .battery: battery = newValue
            case .ac: ac = newValue
            case .ups: ups = newValue
            }
        }
    }

    var isEmpty: Bool { battery == nil && ac == nil && ups == nil }

    /// Zapnuto pro všechny zdroje, které Mac má.
    var isFullyEnabled: Bool {
        !isEmpty && PowerProfile.allCases.allSatisfy { self[$0] != false }
    }

    /// Vypnuto všude – bezpečný směr, když původní hodnoty nejdou zjistit ze značky.
    static let allOff = LowPowerState(battery: false, ac: false, ups: nil)
}

/// Právě platná hodnota `lowpowermode` podle `pmset -g`.
enum LowPowerReading: Sendable, Equatable {
    /// Mac úsporný režim nemá (řádek ve výstupu chybí).
    case unsupported
    /// pmset selhal nebo vrátil nečekanou hodnotu.
    case unreadable
    case value(Bool)
}

// MARK: - Vratné nastavení

/// Jedno systémové nastavení, které daemon umí zapnout a pak vrátit na původní hodnotu.
protocol RevertibleSetting: Sendable {
    /// Hodnota nastavení před zapnutím.
    associatedtype Original: Sendable & Equatable
    /// Podoba značky na disku.
    associatedtype Record: Codable & Sendable

    /// Název pro log.
    var logName: String { get }
    /// Aktuální systémová hodnota; nil, když ji nelze zjistit.
    func read() -> Original?
    /// Je tato hodnota „plně zapnuto"? Pak není co zapisovat ani vracet.
    func isEngaged(_ value: Original) -> Bool
    /// Zapne nastavení. Vrací, zda se to povedlo.
    func engage() -> Bool
    /// Vrátí nastavení na `original`. Zapisuje jen tam, kde původní hodnota nebyla „zapnuto".
    func restore(_ original: Original) -> Bool
    /// Původní hodnota uložená ve značce.
    func original(from record: Record) -> Original
    /// Původní hodnota, když značka existuje, ale nejde přečíst (bezpečný směr: vypnuto).
    var originalForUnreadableMarker: Original { get }
    /// Původní hodnota, když ji před zapnutím nelze přečíst ze systému. nil = nehádat a nezapínat.
    var originalWhenUnreadable: Original? { get }
    /// Držíme nastavení a někdo ho mezitím (celé nebo zčásti) vypnul. Co teď znovu zapneme,
    /// je naše: pro vypnuté části je původní hodnota od této chvíle „vypnuto".
    func original(recorded: Original, afterExternalChangeTo current: Original) -> Original
}

/// `pmset disablesleep`: jedna hodnota pro celý systém.
struct SleepDisabledSetting: RevertibleSetting {
    let power: any PowerSettingApplying

    let logName = "disablesleep"
    let originalForUnreadableMarker = false
    let originalWhenUnreadable: Bool? = false

    func read() -> Bool? { power.readSleepDisabled() }
    func isEngaged(_ value: Bool) -> Bool { value }
    func engage() -> Bool { power.setSleepDisabled(true) }
    func restore(_ original: Bool) -> Bool { original || power.setSleepDisabled(false) }
    func original(from record: MarkerRecord) -> Bool { record.previousSleepDisabled ?? false }
    func original(recorded: Bool, afterExternalChangeTo current: Bool) -> Bool { current && recorded }
}

/// `pmset lowpowermode`: hodnota zvlášť pro baterii, adaptér a UPS.
struct LowPowerSetting: RevertibleSetting {
    let power: any PowerSettingApplying

    let logName = "lowpowermode"
    let originalForUnreadableMarker = LowPowerState.allOff
    /// Bez znalosti původních hodnot se úsporný režim nezapíná.
    let originalWhenUnreadable: LowPowerState? = nil

    func read() -> LowPowerState? { power.readLowPowerProfiles() }
    func isEngaged(_ value: LowPowerState) -> Bool { value.isFullyEnabled }
    func engage() -> Bool { power.setLowPowerMode(true, profile: nil) }

    /// Vypne úsporný režim jen pro zdroje, kde byl před zapnutím vypnutý. Zdroj, kde byl zapnutý
    /// už předtím, se nezapisuje vůbec. Byly-li vypnuté baterie i adaptér (a UPS nebyla zapnutá),
    /// stačí jeden příkaz `pmset -a lowpowermode 0`; jinak `-b`, `-c`, `-u` zvlášť.
    func restore(_ original: LowPowerState) -> Bool {
        let off = PowerProfile.allCases.filter { original[$0] == false }
        if off.isEmpty { return true }
        if original.battery == false, original.ac == false, original.ups != true {
            return power.setLowPowerMode(false, profile: nil)
        }
        // Všechny příkazy se zkusí, i když některý selže; opakování je bezpečné (zapisuje se 0).
        return off.map { power.setLowPowerMode(false, profile: $0) }.allSatisfy { $0 }
    }

    func original(from record: LowPowerMarkerRecord) -> LowPowerState { record.previous }

    func original(recorded: LowPowerState, afterExternalChangeTo current: LowPowerState) -> LowPowerState {
        var result = recorded
        for profile in PowerProfile.allCases {
            switch current[profile] {
            case false?: result[profile] = false          // vypnul to někdo jiný; zapnutí bude naše
            case true?: if result[profile] == nil { result[profile] = true }   // nový zdroj, už zapnutý: není náš
            case nil: break
            }
        }
        return result
    }
}

// MARK: - Držené nastavení

/// Jak vytrvale se nastavení vrací, když zápis selže.
struct RevertRetryPolicy: Sendable {
    /// Počet okamžitých pokusů o vrácení nastavení.
    var attempts: Int
    var attemptDelay: TimeInterval
    /// Když se vrácení nepovede, zkouší se znovu v tomto intervalu, dokud neuspěje.
    var pendingInterval: TimeInterval
}

/// Stav jednoho drženého nastavení: kdo ho drží, původní hodnota, značka na disku a vracení
/// s opakováním. Společná mechanika pro „nikdy neusínat" i úsporný režim.
///
/// Veškerý stav se mění jen na frontě `queue` řídicího objektu (proto `@unchecked Sendable`).
final class HeldSetting<Setting: RevertibleSetting>: @unchecked Sendable {

    typealias ClientID = UUID

    enum EngageFailure: Sendable {
        /// Značku se nepodařilo uložit; nastavení se neměnilo.
        case markerWrite
        /// Původní hodnotu nelze zjistit a nastavení nedovoluje ji odhadnout; nic se neměnilo.
        case originalUnreadable
        /// Zápis nastavení selhal; co se stihlo změnit, se vrátilo (nebo se vrací na pozadí).
        case settingWrite
    }

    private let setting: Setting
    private let marker: any MarkerStoring<Setting.Record>
    private let queue: DispatchQueue
    private let retry: RevertRetryPolicy
    /// Volá se na `queue` po pokusu o vrácení na pozadí.
    private let afterBackgroundRevert: @Sendable () -> Void

    private(set) var held = false
    private(set) var owner: ClientID?
    /// Vrácení se nepovedlo a zkouší se dál na pozadí.
    private(set) var pendingRevert = false
    private(set) var lastStopReason: HelperStopReason = .none
    /// Čas posledního heartbeatu vlastníka podle hodin, které během spánku stojí.
    private(set) var lastHeartbeat: TimeInterval = 0
    /// Hodnota před naším zapnutím; na tu se při vracení obnovuje.
    private var original: Setting.Original
    private var retryWork: DispatchWorkItem?

    init(setting: Setting,
         marker: any MarkerStoring<Setting.Record>,
         queue: DispatchQueue,
         retry: RevertRetryPolicy,
         afterBackgroundRevert: @escaping @Sendable () -> Void) {
        self.setting = setting
        self.marker = marker
        self.queue = queue
        self.retry = retry
        self.afterBackgroundRevert = afterBackgroundRevert
        self.original = setting.originalForUnreadableMarker
    }

    /// Daemon má co vracet: nastavení drží, čeká na opakované vrácení, nebo po něm zůstala značka.
    /// Dokud to platí, daemon nesmí čistě skončit.
    var hasSomethingToRevert: Bool { held || pendingRevert || marker.exists() }

    var markerExists: Bool { marker.exists() }

    func isOwned(by client: ClientID) -> Bool { held && owner == client }

    /// Hodiny, které během spánku stojí – stejně jako lhůty `asyncAfter`. Stáří heartbeatu se měří
    /// jimi, aby probuzení po (vynuceném) spánku nevypadalo jako ztracené spojení s aplikací.
    static func uptimeNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    var heartbeatAge: TimeInterval { Self.uptimeNow() - lastHeartbeat }

    /// Heartbeat od `client`. Vrací, zda nastavení pro tohoto klienta držíme.
    func heartbeat(from client: ClientID) -> Bool {
        guard isOwned(by: client) else { return false }
        lastHeartbeat = Self.uptimeNow()
        return true
    }

    /// Po startu daemona: zbylá značka znamená, že předchozí běh neskončil čistě.
    func recoverAfterRestart() {
        guard marker.exists() else { return }
        helperLog.notice("Nalezena značka z předchozího běhu, vracím \(self.setting.logName, privacy: .public) na původní hodnotu")
        lastStopReason = .helperRestarted
        loadOriginalFromMarker()
        _ = revert()
    }

    /// Zapne nastavení pro `client` (nebo jen převezme vlastnictví, když už ho držíme).
    /// `makeRecord` sestaví značku z původní hodnoty. Vrací nil při úspěchu.
    func engage(client: ClientID, makeRecord: (Setting.Original) -> Setting.Record) -> EngageFailure? {
        if held {
            // Už držíme: jen nová značka, případně nový vlastník.
            if let current = setting.read(), !setting.isEngaged(current) {
                // Někdo mezitím nastavení vypnul (i ten, kdo ho měl zapnuté před námi). Co teď
                // zapneme, je naše, takže původní hodnota je od této chvíle „vypnuto".
                original = setting.original(recorded: original, afterExternalChangeTo: current)
                guard marker.write(makeRecord(original)), setting.engage() else {
                    stop(reason: .requestedByApp)
                    return .settingWrite
                }
            } else {
                _ = marker.write(makeRecord(original))
            }
        } else {
            // Původní hodnota: zbylá značka nebo čekající vrácení znamenají, že současný stav je
            // náš, proto platí dřív zaznamenaná hodnota. Jinak se čte ze systému PŘED jakoukoli změnou.
            let previous: Setting.Original
            if pendingRevert {
                previous = original
            } else if marker.exists() {
                previous = marker.read().map(setting.original(from:)) ?? setting.originalForUnreadableMarker
            } else if let current = setting.read() ?? setting.originalWhenUnreadable {
                previous = current
            } else {
                return .originalUnreadable
            }
            // Značka musí být na disku DŘÍV, než se nastavení změní. Případný čekající pokus
            // o vrácení (`retryWork`) tu zůstává naplánovaný, dokud zapnutí opravdu neuspěje.
            // Když zápis selže a žádná dřívější značka neexistovala, nesmí po něm nic zůstat:
            // zbytek by se později četl jako „původně vypnuto" a přepsal by cizí nastavení.
            let hadMarker = pendingRevert || marker.exists()
            guard marker.write(makeRecord(previous)) else {
                if !hadMarker { _ = marker.remove() }
                return .markerWrite
            }
            original = previous
            // Bylo-li nastavení zapnuté už před námi, není co zapisovat.
            let alreadyEngaged = setting.isEngaged(previous) && setting.read().map(setting.isEngaged) == true
            guard alreadyEngaged || (setting.engage() && setting.read().map(setting.isEngaged) != false) else {
                helperLog.error("Zapnutí \(self.setting.logName, privacy: .public) selhalo")
                _ = revert()
                return .settingWrite
            }
            pendingRevert = false
            held = true
            retryWork?.cancel()
            retryWork = nil
            helperLog.notice("\(self.setting.logName, privacy: .public): zapnuto")
        }
        owner = client
        lastHeartbeat = Self.uptimeNow()
        lastStopReason = .none
        return nil
    }

    /// Ukončí držení a vrátí nastavení. Vrací, zda se vrácení povedlo hned.
    @discardableResult
    func stop(reason: HelperStopReason) -> Bool {
        helperLog.notice("\(self.setting.logName, privacy: .public): vypínám, důvod \(reason.rawValue, privacy: .public)")
        held = false
        owner = nil
        lastStopReason = reason
        return revert()
    }

    /// Vrátí vše, co po nás zbylo: držené nastavení, čekající vrácení i osiřelou značku.
    /// Když není co vracet, neudělá nic (cizí nastavení se nikdy nemění).
    func release(reason: HelperStopReason) -> Bool {
        if held { return stop(reason: reason) }
        if pendingRevert { return revert() }
        if marker.exists() {
            loadOriginalFromMarker()
            return revert()
        }
        return true
    }

    /// Daemon končí: další pokus na pozadí by stejně neproběhl.
    func cancelBackgroundRevert() {
        retryWork?.cancel()
        retryWork = nil
    }

    // MARK: Interní

    /// Načte ze značky hodnotu před zapnutím. Nečitelná značka = bezpečný směr (vypnuto).
    private func loadOriginalFromMarker() {
        original = marker.read().map(setting.original(from:)) ?? setting.originalForUnreadableMarker
    }

    /// Vrátí nastavení na hodnotu před zapnutím. Bylo-li už tehdy zapnuté (nastavil ho někdo jiný),
    /// nechá ho být a jen smaže značku; jinak zapisuje s několika pokusy. Při neúspěchu zůstává
    /// značka a zkouší se dál na pozadí.
    private func revert() -> Bool {
        retryWork?.cancel()
        retryWork = nil
        if setting.isEngaged(original) {
            _ = marker.remove()
            original = setting.originalForUnreadableMarker
            pendingRevert = false
            return true
        }
        for attempt in 1...max(1, retry.attempts) {
            if setting.restore(original) {
                _ = marker.remove()
                pendingRevert = false
                return true
            }
            helperLog.error("Vrácení \(self.setting.logName, privacy: .public) selhalo (pokus \(attempt, privacy: .public))")
            if attempt < retry.attempts {
                Thread.sleep(forTimeInterval: retry.attemptDelay)
            }
        }
        pendingRevert = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingRevert, !self.held else { return }
            _ = self.revert()
            self.afterBackgroundRevert()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + retry.pendingInterval, execute: work)
        return false
    }
}
