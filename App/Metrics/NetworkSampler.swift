import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Rychlost sítě z čítačů rozhraní (`getifaddrs`, záznamy AF_LINK).
///
/// Sčítají se jen fyzická rozhraní, která jsou zapnutá a běží (Wi-Fi, Ethernet, USB/Thunderbolt adaptéry,
/// sdílení z iPhonu – všechna se jmenují `enN`). Vynechává se loopback a virtuální rozhraní:
/// provoz VPN (`utun`, `ipsec`, `ppp`) nebo mostu (`bridge`) už jednou prošel fyzickým rozhraním
/// a počítal by se dvakrát; `awdl`/`llw`/`nan` (AirDrop, Wi-Fi Aware) a `ap` sdílejí rádio s Wi-Fi;
/// `gif`/`stf` jsou tunely; `anpi` je interní spojení s koprocesorem; `vmnet`/`vmenet`/`feth`/`tap`/`tun`
/// patří virtuálním strojům.
struct NetworkSampler {
    private struct Counters {
        var received: UInt32
        var sent: UInt32
    }

    private static let skippedPrefixes: Set<String> = [
        "lo", "utun", "ipsec", "ppp", "awdl", "llw", "nan", "bridge", "gif", "stf", "anpi", "ap",
        "vmnet", "vmenet", "feth", "tap", "tun",
    ]
    /// Strop věrohodné rychlosti (10 Gb/s). Vyšší „rychlost" po poklesu čítače znamená jeho vynulování, ne přetečení.
    private static let maxBytesPerSecond = 1.25e9
    /// SSID a primární rozhraní se zjišťují přes jiné procesy, proto jen občas.
    private static let infoLifetime = 10.0
    /// Dokud název sítě chybí (čerstvě udělené oprávnění, připojování), zkoušíme to častěji.
    private static let missingInfoLifetime = 5.0

    private var previous: [String: Counters]?
    private var previousAt: UInt64 = 0
    private var lastRates: (down: Double, up: Double)?

    private var ssid: String?
    private var primaryInterface: String?
    private var wifiActive = false
    private var infoAt: UInt64?

    init() {}

    /// Uloží výchozí stav čítačů bez dotazu na SSID (levné, smí běžet i na hlavním vlákně).
    mutating func prime() {
        previous = Self.readCounters()
        previousAt = DispatchTime.now().uptimeNanoseconds
        // Rychlost z dřívějška už k novému výchozímu stavu nepatří.
        lastRates = nil
    }

    /// Název sítě a primární rozhraní se při příštím vzorku načtou znovu.
    mutating func invalidateInfo() {
        infoAt = nil
    }

    /// První volání bez `prime()` vrací `nil` (není s čím porovnat). Rychlosti nejsou nikdy záporné.
    mutating func sample() -> NetworkMetrics? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let current = Self.readCounters() else {
            previous = nil
            lastRates = nil
            return nil
        }
        refreshInfoIfNeeded(now: now)

        guard let previous else {
            self.previous = current
            previousAt = now
            return nil
        }

        let elapsed = Double(now &- previousAt) / 1e9
        // Příliš krátký interval dává nesmyslné špičky: vrátíme poslední výsledek a stav neměníme.
        guard elapsed >= 0.1 else {
            return lastRates.map { metrics(down: $0.down, up: $0.up) }
        }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, counters) in current {
            // Nové rozhraní se započítá až od příštího vzorku; zmizelé prostě vypadne.
            guard let before = previous[name] else { continue }
            received += Self.delta(from: before.received, to: counters.received, elapsed: elapsed)
            sent += Self.delta(from: before.sent, to: counters.sent, elapsed: elapsed)
        }
        self.previous = current
        previousAt = now

        let rates = (down: Double(received) / elapsed, up: Double(sent) / elapsed)
        lastRates = rates
        return metrics(down: rates.down, up: rates.up)
    }

    private func metrics(down: Double, up: Double) -> NetworkMetrics {
        NetworkMetrics(downloadBytesPerSecond: down, uploadBytesPerSecond: up, ssid: ssid, primaryInterface: primaryInterface,
                       wifiActive: wifiActive)
    }

    /// Čítače v `if_data` jsou 32bitové. Pokles znamená buď jedno přetečení (pak vyjde věrohodný rozdíl),
    /// nebo vynulování po restartu rozhraní (pak rozdíl zahodíme).
    private static func delta(from old: UInt32, to new: UInt32, elapsed: Double) -> UInt64 {
        let difference = UInt64(new &- old)
        if new < old, Double(difference) / elapsed > maxBytesPerSecond { return 0 }
        return difference
    }

    private static func readCounters() -> [String: Counters]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var result: [String: Counters] = [:]
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard let address = interface.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let data = interface.ifa_data else { continue }
            let flags = Int32(bitPattern: interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            let prefix = String(name.prefix { !$0.isNumber })
            guard !skippedPrefixes.contains(prefix) else { continue }

            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = Counters(received: counters.ifi_ibytes, sent: counters.ifi_obytes)
        }
        return result
    }

    private mutating func refreshInfoIfNeeded(now: UInt64) {
        let lifetime = ssid == nil ? Self.missingInfoLifetime : Self.infoLifetime
        if let infoAt, Double(now &- infoAt) / 1e9 < lifetime { return }
        infoAt = now
        let wifi = CWWiFiClient.shared().interface()
        // Bez oprávnění k poloze vrací systém nil; o oprávnění se tady nežádá.
        ssid = wifi?.ssid()
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        primaryInterface = global?["PrimaryInterface"] as? String
        wifiActive = wifi?.powerOn() == true && wifi?.interfaceName != nil
            && wifi?.interfaceName == primaryInterface
    }
}
