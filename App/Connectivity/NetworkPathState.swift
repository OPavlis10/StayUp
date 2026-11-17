import Network

/// Stav síťové cesty podle systému (NWPath.Status).
enum NetworkLinkStatus: Sendable, Equatable {
    /// Existuje použitelná trasa ven.
    case satisfied
    /// Žádná použitelná trasa (vypnutá Wi-Fi, vytažený kabel, režim Letadlo…).
    case unsatisfied
    /// Trasa by vznikla až po navázání spojení (např. VPN na vyžádání); teď použitelná není.
    case requiresConnection
}

/// Druh rozhraní, přes které cesta vede.
enum NetworkInterfaceKind: Sendable, Equatable {
    case wifi
    case ethernet
    case cellular
    /// Cokoli jiného (VPN tunel, most, loopback…).
    case other
}

/// Neměnný snímek síťové cesty tak, jak ho hlásí NWPathMonitor.
///
/// Poctivě: `satisfied` znamená jen to, že systém má použitelnou trasu (rozhraní s adresou
/// a výchozí bránou). NEdokazuje to, že internet opravdu funguje. Wi-Fi s přihlašovací
/// stránkou (captive portal), router bez linky k poskytovateli nebo firewall vypadají
/// jako „připojeno". Ověřit to by šlo jen odesláním dat, a to aplikace z principu nedělá.
struct NetworkPathState: Sendable, Equatable {
    var status: NetworkLinkStatus
    /// Hlavní (systémem preferované) rozhraní; `nil`, když žádné není k dispozici.
    var interface: NetworkInterfaceKind?
    /// Placené/omezené připojení (osobní hotspot, mobilní data).
    var isExpensive: Bool
    /// Uživatel zapnul Režim malého objemu dat.
    var isConstrained: Bool

    /// Jediný stav, který se bere jako „je připojení".
    var isUsable: Bool { status == .satisfied }

    init(status: NetworkLinkStatus, interface: NetworkInterfaceKind?, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.status = status
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(_ path: NWPath) {
        switch path.status {
        case .satisfied: status = .satisfied
        case .requiresConnection: status = .requiresConnection
        case .unsatisfied: status = .unsatisfied
        @unknown default: status = .unsatisfied
        }
        // availableInterfaces je seřazené podle preference systému; první je to, které se použije.
        interface = path.availableInterfaces.first.map { Self.kind(of: $0.type) }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
    }

    private static func kind(of type: NWInterface.InterfaceType) -> NetworkInterfaceKind {
        switch type {
        case .wifi: .wifi
        case .wiredEthernet: .ethernet
        case .cellular: .cellular
        case .loopback, .other: .other
        @unknown default: .other
        }
    }
}
