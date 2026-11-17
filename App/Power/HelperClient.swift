import Foundation
import ServiceManagement

/// Stav registrace daemonu v systému (SMAppService).
enum HelperRegistration: Sendable, Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
}

/// Odpověď daemonu na `getStatus`.
struct HelperStatus: Sendable, Equatable {
    var protocolVersion: Int
    /// Aktuální systémová hodnota SleepDisabled.
    var sleepDisabled: Bool
    /// Drží režim právě daemon?
    var heldByHelper: Bool

    var isCompatible: Bool { protocolVersion == HelperConstants.protocolVersion }
}

/// Odpověď daemonu na `getLowPowerStatus`.
struct HelperLowPowerStatus: Sendable, Equatable {
    /// Mac úsporný režim má. Když ne, daemon ho odmítne zapnout.
    var supported: Bool
    /// Aktuální systémová hodnota (může být zapnutá i z Nastavení systému).
    var enabled: Bool
    /// Drží úsporný režim právě daemon (nebo po něm zůstalo nevrácené nastavení)?
    var heldByHelper: Bool
}

/// Odpověď daemonu na heartbeat. Oba režimy hlásí stav nezávisle na sobě.
struct HelperHeartbeat: Sendable, Equatable {
    /// Režim „nikdy neusínat": drží ho daemon pro toto spojení? Když ne, `stopReason` říká proč.
    var active: Bool
    var stopReason: HelperStopReason
    /// Úsporný režim: drží ho daemon pro toto spojení? Když ne, `lowPowerStopReason` říká proč.
    var lowPowerActive: Bool
    var lowPowerStopReason: HelperStopReason
}

/// Co se stalo s XPC spojením.
enum HelperConnectionEvent: Sendable {
    /// Daemon skončil nebo spadl; spojení lze použít znovu.
    case interrupted
    /// Spojení zaniklo; další volání si vytvoří nové.
    case invalidated
}

enum HelperClientError: Error, LocalizedError, Sendable, Equatable {
    case connection(String)
    case timeout
    case incompatibleVersion(found: Int)
    case helperFailed(String?)
    case registration(String)
    case unregistration(String)

    var errorDescription: String? {
        switch self {
        case .connection(let detail):
            String(localized: "Spojení s pomocným procesem selhalo: \(detail)")
        case .timeout:
            String(localized: "Pomocný proces neodpověděl včas.")
        case .incompatibleVersion(let found):
            String(localized: "Pomocný proces má jinou verzi (\(found)) než aplikace (\(HelperConstants.protocolVersion)). Zaregistrujte ho znovu.")
        case .helperFailed(let detail):
            if let detail, !detail.isEmpty {
                String(localized: "Pomocný proces ohlásil chybu: \(detail)")
            } else {
                String(localized: "Pomocný proces ohlásil chybu.")
            }
        case .registration(let detail):
            String(localized: "Pomocný proces se nepodařilo zaregistrovat: \(detail)")
        case .unregistration(let detail):
            String(localized: "Pomocný proces se nepodařilo odregistrovat: \(detail)")
        }
    }
}

/// Klient privilegovaného daemonu: registrace přes SMAppService a volání přes XPC.
/// Všechny metody jsou bezpečné z libovolného vlákna; asynchronní běží mimo hlavní vlákno.
final class HelperClient: @unchecked Sendable {
    /// Jak dlouho se čeká na odpověď daemonu.
    static let replyTimeout: TimeInterval = 5

    // Chráněno zámkem.
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var generation = 0
    private var closed = false
    private var connectionHandler: (@Sendable (HelperConnectionEvent) -> Void)?

    init() {}

    deinit { invalidate() }

    // MARK: - Registrace (SMAppService)

    private static var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    private static func map(_ status: SMAppService.Status) -> HelperRegistration {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    /// Aktuální stav registrace daemonu.
    @concurrent
    func registrationStatus() async -> HelperRegistration {
        Self.map(Self.service.status)
    }

    /// Zaregistruje daemon. Když systém čeká na schválení uživatelem, vrátí `.requiresApproval` (nevyhazuje).
    @concurrent
    func register() async throws -> HelperRegistration {
        let service = Self.service
        if service.status == .enabled { return .enabled }
        do {
            try service.register()
        } catch {
            let status = Self.map(service.status)
            if status == .requiresApproval || status == .enabled { return status }
            throw HelperClientError.registration(error.localizedDescription)
        }
        return Self.map(service.status)
    }

    /// Odregistruje daemon (a zruší spojení).
    @concurrent
    func unregister() async throws {
        invalidate()
        do {
            try await Self.service.unregister()
        } catch {
            throw HelperClientError.unregistration(error.localizedDescription)
        }
    }

    /// Otevře Nastavení systému › Obecné › Položky přihlášení.
    static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Spojení

    /// Volá se (na libovolném vlákně), když spojení přeruší nebo ukončí druhá strana.
    /// Vlastní `invalidate()` handler nevolá.
    func setConnectionHandler(_ handler: (@Sendable (HelperConnectionEvent) -> Void)?) {
        lock.withLock { connectionHandler = handler }
    }

    /// Je spojení s daemonem otevřené?
    var hasConnection: Bool {
        lock.withLock { connection != nil }
    }

    /// Zruší spojení. Daemon má oba režimy vázané na spojení, takže je tím sám vrátí.
    func invalidate() {
        let old: NSXPCConnection? = lock.withLock {
            let current = connection
            connection = nil
            generation += 1
            return current
        }
        old?.invalidate()
    }

    /// Zruší spojení natrvalo (ukončení aplikace); další volání už nové spojení nevytvoří.
    func close() {
        lock.withLock { closed = true }
        invalidate()
    }

    private func currentConnection() -> NSXPCConnection? {
        lock.withLock {
            if closed { return nil }
            if let connection { return connection }
            generation += 1
            let id = generation
            let new = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            new.interruptionHandler = { [weak self] in
                self?.connectionEnded(generation: id, event: .interrupted)
            }
            new.invalidationHandler = { [weak self] in
                self?.connectionEnded(generation: id, event: .invalidated)
            }
            new.activate()
            connection = new
            return new
        }
    }

    private func connectionEnded(generation id: Int, event: HelperConnectionEvent) {
        let handler: (@Sendable (HelperConnectionEvent) -> Void)? = lock.withLock {
            guard id == generation else { return nil }   // staré nebo námi zrušené spojení
            if case .invalidated = event { connection = nil }
            return connectionHandler
        }
        handler?(event)
    }

    private func proxy(onError: @escaping @Sendable (any Error) -> Void) -> (any HelperXPCProtocol)? {
        currentConnection()?.remoteObjectProxyWithErrorHandler(onError) as? any HelperXPCProtocol
    }

    // MARK: - Volání daemonu

    /// Stav daemonu včetně verze protokolu (viz `HelperStatus.isCompatible`).
    @concurrent
    func getStatus() async throws -> HelperStatus {
        try await call { proxy, finish in
            proxy.getStatus { version, sleepDisabled, held in
                finish(.success(HelperStatus(protocolVersion: version, sleepDisabled: sleepDisabled, heldByHelper: held)))
            }
        }
    }

    /// Jako `getStatus`, ale při jiné verzi protokolu vyhodí `.incompatibleVersion`.
    @concurrent
    func checkedStatus() async throws -> HelperStatus {
        let status = try await getStatus()
        guard status.isCompatible else {
            throw HelperClientError.incompatibleVersion(found: status.protocolVersion)
        }
        return status
    }

    /// Zapne `disablesleep 1`. `expiresAfter` 0 = bez limitu, práh baterie 0 = nehlídat.
    @concurrent
    func enableNoSleep(batteryThresholdPercent: Int, thermalLimit: ThermalLimit, expiresAfter: TimeInterval) async throws {
        try await call { (proxy, finish: @escaping @Sendable (Result<Void, HelperClientError>) -> Void) in
            proxy.enableNoSleep(batteryThresholdPercent: batteryThresholdPercent,
                                thermalLimit: thermalLimit,
                                expiresAfter: expiresAfter) { success, message in
                finish(success ? .success(()) : .failure(.helperFailed(message)))
            }
        }
    }

    /// Vrátí `disablesleep` na 0.
    @concurrent
    func disableNoSleep() async throws {
        try await call { (proxy, finish: @escaping @Sendable (Result<Void, HelperClientError>) -> Void) in
            proxy.disableNoSleep { success, message in
                finish(success ? .success(()) : .failure(.helperFailed(message)))
            }
        }
    }

    @concurrent
    func heartbeat() async throws -> HelperHeartbeat {
        try await call { proxy, finish in
            proxy.heartbeat { active, reason, lowPowerActive, lowPowerReason in
                finish(.success(HelperHeartbeat(active: active,
                                                stopReason: HelperStopReason(rawValue: reason) ?? .none,
                                                lowPowerActive: lowPowerActive,
                                                lowPowerStopReason: HelperStopReason(rawValue: lowPowerReason) ?? .none)))
            }
        }
    }

    // MARK: - Úsporný režim

    /// Stav úsporného režimu. Volat až po `checkedStatus()` – starší daemon tuto metodu nemá.
    @concurrent
    func lowPowerStatus() async throws -> HelperLowPowerStatus {
        try await call { proxy, finish in
            proxy.getLowPowerStatus { supported, enabled, held in
                finish(.success(HelperLowPowerStatus(supported: supported, enabled: enabled, heldByHelper: held)))
            }
        }
    }

    /// Zapne `lowpowermode 1` pro všechny zdroje napájení. Na Macu bez úsporného režimu vyhodí `.helperFailed`.
    @concurrent
    func enableLowPower() async throws {
        try await call { (proxy, finish: @escaping @Sendable (Result<Void, HelperClientError>) -> Void) in
            proxy.enableLowPower { success, message in
                finish(success ? .success(()) : .failure(.helperFailed(message)))
            }
        }
    }

    /// Vrátí `lowpowermode` na hodnoty před zapnutím.
    @concurrent
    func disableLowPower() async throws {
        try await call { (proxy, finish: @escaping @Sendable (Result<Void, HelperClientError>) -> Void) in
            proxy.disableLowPower { success, message in
                finish(success ? .success(()) : .failure(.helperFailed(message)))
            }
        }
    }

    /// Synchronní vypnutí obou režimů pro ukončení aplikace: na obě odpovědi dohromady čeká
    /// nejvýše `timeout` sekund. Smí se volat z hlavního vlákna (odpovědi přicházejí na frontě spojení).
    /// Co se nestihne, vrátí daemon sám, jakmile spojení zanikne.
    @discardableResult
    func disableAllBlocking(timeout: TimeInterval) -> (noSleep: Bool, lowPower: Bool) {
        let done = DispatchSemaphore(value: 0)
        let noSleep = Once<Bool>()
        let lowPower = Once<Bool>()
        guard let proxy = proxy(onError: { _ in
            // Chyba spojení ukončí obě čekání; `claim` pustí dál jen první výsledek každého z nich.
            if noSleep.claim(false) { done.signal() }
            if lowPower.claim(false) { done.signal() }
        }) else { return (false, false) }
        proxy.disableNoSleep { success, _ in
            if noSleep.claim(success) { done.signal() }
        }
        proxy.disableLowPower { success, _ in
            if lowPower.claim(success) { done.signal() }
        }
        let deadline = DispatchTime.now() + timeout
        for _ in 0..<2 where done.wait(timeout: deadline) != .success { break }
        return (noSleep.value ?? false, lowPower.value ?? false)
    }

    /// Synchronní vypnutí pro ukončení aplikace: čeká na odpověď nejvýše `timeout` sekund.
    /// Smí se volat z hlavního vlákna (odpověď přichází na frontě spojení).
    @discardableResult
    func disableNoSleepBlocking(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let outcome = Once<Bool>()
        guard let proxy = proxy(onError: { _ in
            if outcome.claim(false) { done.signal() }
        }) else { return false }
        proxy.disableNoSleep { success, _ in
            if outcome.claim(success) { done.signal() }
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return false }
        return outcome.value ?? false
    }

    /// Společný obal: continuation se obnoví právě jednou – odpovědí, chybou XPC nebo vypršením času.
    private func call<T: Sendable>(
        _ body: (any HelperXPCProtocol, @escaping @Sendable (Result<T, HelperClientError>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let once = Once<Bool>()
            let finish: @Sendable (Result<T, HelperClientError>) -> Void = { result in
                guard once.claim(true) else { return }
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            guard let proxy = proxy(onError: { error in
                finish(.failure(.connection(error.localizedDescription)))
            }) else {
                finish(.failure(.connection(String(localized: "rozhraní pomocného procesu není dostupné"))))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.replyTimeout) {
                finish(.failure(.timeout))
            }
            body(proxy, finish)
        }
    }
}

/// Hodnota, kterou lze nastavit jen jednou (první volající vyhrává).
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    /// Vrací `true` jen prvnímu volajícímu.
    func claim(_ value: Value) -> Bool {
        lock.withLock {
            guard stored == nil else { return false }
            stored = value
            return true
        }
    }

    var value: Value? { lock.withLock { stored } }
}
