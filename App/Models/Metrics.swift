import Foundation

// Datové typy přehledu systému. Vše je Sendable, vzniká v actoru MetricsCollector
// a čte se na hlavním vlákně. Chybějící údaj je vždy `nil`, nikdy vymyšlená hodnota.

struct CPUMetrics: Sendable, Equatable {
    /// Celkové využití 0...1 (user + system + nice přes všechna jádra).
    var total: Double
    /// Využití jednotlivých jader 0...1, v pořadí podle systému.
    var perCore: [Double]
}

enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

struct MemoryMetrics: Sendable, Equatable {
    /// Fyzická paměť celkem, v bajtech.
    var total: UInt64
    /// Využito (aplikace + wired + komprimované), stejně jako „Využitá paměť" v Monitoru aktivity.
    var used: UInt64
    /// Volné (total - used).
    var free: UInt64
    /// Komprimovaná paměť.
    var compressed: UInt64
    /// Tlak paměti; `nil`, když ho systém nevydá.
    var pressure: MemoryPressure?
}

/// Řádek Paměť tak, jak je vidět: hotové texty a zaokrouhlený podíl. Surové bajty se mění každou
/// sekundu, zobrazený text jen občas – porovnává se proto tohle, ne `MemoryMetrics`.
struct MemoryDisplay: Sendable, Equatable {
    /// Např. „12,4 GB z 24 GB".
    var usedText: String
    /// Např. „Volné 11,6 GB · Komprimované 850 MB".
    var detailText: String
    /// Podíl využité paměti 0...1, zaokrouhlený na krok, který je na ukazateli vidět.
    var usedFraction: Double
    var pressure: MemoryPressure?
}

struct DiskMetrics: Sendable, Equatable {
    var total: UInt64
    /// Volné místo včetně uvolnitelného (volumeAvailableCapacityForImportantUsage), jako ve Finderu.
    var free: UInt64
    var used: UInt64 { total >= free ? total - free : 0 }
}

struct GPUMetrics: Sendable, Equatable {
    /// Využití 0...1.
    var utilization: Double
    /// Název akcelerátoru, pokud je znám.
    var name: String?
}

struct NetworkMetrics: Sendable, Equatable {
    /// Bajty za sekundu, součet přes fyzická rozhraní (bez loopbacku).
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    /// Název Wi-Fi sítě; `nil`, když není Wi-Fi, není připojeno nebo chybí oprávnění k poloze.
    var ssid: String?
    /// Název primárního rozhraní (např. en0), pokud je znám.
    var primaryInterface: String?
    /// Wi-Fi je zapnutá a je primárním připojením. Jen tehdy má smysl nabízet oprávnění k poloze.
    var wifiActive = false
}

struct SystemSnapshot: Sendable, Equatable {
    var timestamp: Date
    var cpu: CPUMetrics?
    var memory: MemoryMetrics?
    var disk: DiskMetrics?
    var gpu: GPUMetrics?
    var network: NetworkMetrics?
}
