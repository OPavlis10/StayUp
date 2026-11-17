import Foundation

/// Místo na systémovém disku. Mění se pomalu a jedno čtení stojí desítky ms CPU (systém se ptá
/// služby na uvolnitelné místo), proto se výsledek drží v mezipaměti.
struct DiskSampler {
    private let cacheLifetime: TimeInterval
    private var cached: DiskMetrics?
    private var cachedAt: UInt64 = 0

    /// Datový svazek je ten, na který se zapisuje a který ukazuje Finder; „/" je zapečetěný systémový svazek
    /// ve stejném kontejneru APFS a slouží jako záloha.
    private static let paths = ["/System/Volumes/Data", "/"]
    private static let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]

    init(cacheLifetime: TimeInterval = 120) {
        self.cacheLifetime = cacheLifetime
    }

    /// `maxAge` zkrátí platnost mezipaměti pro toto volání (např. těsně po otevření panelu).
    mutating func sample(maxAge: TimeInterval? = nil) -> DiskMetrics? {
        let now = DispatchTime.now().uptimeNanoseconds
        let lifetime = min(cacheLifetime, maxAge ?? cacheLifetime)
        if let cached, Double(now &- cachedAt) / 1e9 < lifetime { return cached }
        let fresh = Self.read()
        cached = fresh
        cachedAt = now
        return fresh
    }

    private static func read() -> DiskMetrics? {
        for path in paths {
            // Nová URL při každém čtení: hodnoty zdrojů se na instanci URL ukládají do mezipaměti.
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity, total > 0,
                  let free = values.volumeAvailableCapacityForImportantUsage, free >= 0 else { continue }
            let totalBytes = UInt64(total)
            return DiskMetrics(total: totalBytes, free: min(UInt64(free), totalBytes))
        }
        return nil
    }
}
