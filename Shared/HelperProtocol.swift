import Foundation

/// Konstanty sdílené mezi aplikací a privilegovaným pomocným procesem.
enum HelperConstants {
    /// Název Mach služby, kterou daemon vystavuje (musí odpovídat LaunchDaemon plistu).
    static let machServiceName = "cz.stayup.StayUp.helper"
    /// Název plistu v `Contents/Library/LaunchDaemons/` uvnitř balíčku aplikace.
    static let daemonPlistName = "cz.stayup.StayUp.helper.plist"
    /// Bundle identifier hlavní aplikace.
    static let appBundleID = "cz.stayup.StayUp"
    /// Verze XPC protokolu. Při nekompatibilní změně zvýšit.
    static let protocolVersion = 2
    /// Jak často aplikace posílá heartbeat, když daemon drží režim B nebo úsporný režim.
    static let heartbeatInterval: TimeInterval = 10
    /// Po jak dlouhé době bez heartbeatu daemon držené režimy sám vypne.
    static let heartbeatTimeout: TimeInterval = 35
}

/// Důvod, proč daemon držený režim ukončil. Přenáší se přes XPC jako Int.
/// Pro „nikdy neusínat" platí všechny, pro úsporný režim jen `requestedByApp`, `clientDisconnected`,
/// `heartbeatTimeout` a `helperRestarted` (pojistky baterie, teploty a časovače se ho netýkají).
enum HelperStopReason: Int, Sendable {
    case none = 0
    case requestedByApp = 1
    case clientDisconnected = 2
    case heartbeatTimeout = 3
    case timerExpired = 4
    case lowBattery = 5
    case thermal = 6
    case helperRestarted = 7
}

/// Úroveň tepelného stavu, od které se má režim B vypnout.
/// Hodnoty odpovídají `ProcessInfo.ThermalState.rawValue` (1 = fair, 2 = serious, 3 = critical).
/// 0 znamená „teplotu nehlídat".
typealias ThermalLimit = Int

/// XPC rozhraní privilegovaného pomocného procesu.
///
/// Daemon má záměrně jen dvě na sobě nezávislé schopnosti: `pmset disablesleep` (režim „nikdy
/// neusínat") a `pmset lowpowermode` (úsporný režim). Každý režim je vázaný na XPC spojení, které
/// ho zapnulo: když spojení zanikne, daemon nastavení vrátí na původní hodnotu. Oba režimy drží
/// naživu jeden společný heartbeat.
@objc protocol HelperXPCProtocol {
    /// Vrátí verzi protokolu, aktuální systémovou hodnotu SleepDisabled a zda má daemon co vracet
    /// (režim drží, nebo po něm zůstalo nevrácené nastavení). `sleepDisabled` může být 1 i z jiného zdroje.
    /// Podpis se mezi verzemi protokolu nemění, aby šla verze zjistit i u staršího daemona.
    func getStatus(reply: @escaping @Sendable (_ protocolVersion: Int, _ sleepDisabled: Bool, _ heldByHelper: Bool) -> Void)

    /// Zapne `disablesleep 1`. Daemon si předtím zapamatuje původní hodnotu.
    /// - Parameters:
    ///   - batteryThresholdPercent: při nabití pod touto hodnotou (a běhu na baterii) daemon režim vypne. 0 = nehlídat.
    ///   - thermalLimit: viz `ThermalLimit`.
    ///   - expiresAfter: počet sekund, po kterých se režim sám vypne. 0 = bez limitu.
    func enableNoSleep(batteryThresholdPercent: Int,
                       thermalLimit: Int,
                       expiresAfter: Double,
                       reply: @escaping @Sendable (_ success: Bool, _ errorMessage: String?) -> Void)

    /// Vrátí `disablesleep` na hodnotu před zapnutím. Když daemon režim nedrží a nic po něm
    /// nezbylo, neudělá nic – nastavení, které nezměnil, nikdy nepřepisuje.
    func disableNoSleep(reply: @escaping @Sendable (_ success: Bool, _ errorMessage: String?) -> Void)

    /// Stav úsporného režimu (od verze protokolu 2).
    /// - `supported`: Mac nastavení `lowpowermode` má (řádek ve výstupu `pmset -g`).
    /// - `enabled`: aktuální systémová hodnota; může být 1 i z jiného zdroje (Nastavení systému).
    /// - `heldByHelper`: daemon má co vracet (režim drží, nebo po něm zůstalo nevrácené nastavení).
    func getLowPowerStatus(reply: @escaping @Sendable (_ supported: Bool, _ enabled: Bool, _ heldByHelper: Bool) -> Void)

    /// Zapne `lowpowermode 1` pro všechny zdroje napájení. Daemon si předtím zapamatuje původní
    /// hodnoty (zvlášť pro baterii a adaptér). Na Macu bez úsporného režimu vrátí chybu.
    /// Pojistky baterie, teploty a časovače se úsporného režimu netýkají.
    func enableLowPower(reply: @escaping @Sendable (_ success: Bool, _ errorMessage: String?) -> Void)

    /// Vrátí `lowpowermode` na hodnoty před zapnutím. Když daemon režim nedrží a nic po něm
    /// nezbylo, neudělá nic.
    func disableLowPower(reply: @escaping @Sendable (_ success: Bool, _ errorMessage: String?) -> Void)

    /// Aplikace volá každých `heartbeatInterval` sekund, dokud je některý režim aktivní.
    /// Odpověď říká pro každý režim zvlášť, zda ho daemon pro toto spojení stále drží, a případně
    /// proč ho ukončil (`HelperStopReason.rawValue`).
    func heartbeat(reply: @escaping @Sendable (_ noSleepActive: Bool,
                                               _ noSleepStopReason: Int,
                                               _ lowPowerActive: Bool,
                                               _ lowPowerStopReason: Int) -> Void)
}
