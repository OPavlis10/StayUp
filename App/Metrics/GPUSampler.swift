import Foundation
import IOKit

/// Využití GPU z registru IOKit (`IOAccelerator` → `PerformanceStatistics`).
struct GPUSampler {
    /// Klíče v pořadí podle priority. První platí na Apple Silicon i u většiny ovladačů Intel/AMD.
    private static let utilizationKeys = ["Device Utilization %", "GPU Activity(%)"]

    /// Název se nemění, čte se jen jednou.
    private var name: String?
    private var nameResolved = false

    init() {}

    /// Při více akcelerátorech vrací ten nejvytíženější. `nil`, když systém údaj nevydá.
    mutating func sample() -> GPUMetrics? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var bestName: String?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let percent = Self.utilization(in: stats) else { continue }
            if best == nil || percent > best! {
                best = percent
                if !nameResolved { bestName = Self.name(of: entry) }
            }
        }
        guard let best else { return nil }
        if !nameResolved {
            name = bestName
            nameResolved = true
        }
        return GPUMetrics(utilization: min(max(best / 100, 0), 1), name: name)
    }

    private static func utilization(in stats: [String: Any]) -> Double? {
        for key in utilizationKeys {
            if let number = stats[key] as? NSNumber { return number.doubleValue }
        }
        return nil
    }

    /// Vlastnost „model" bývá text nebo data (C řetězec); hledá se i u rodičů (na Intelu je na PCI zařízení).
    private static func name(of entry: io_registry_entry_t) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "model" as CFString, kCFAllocatorDefault, options) else {
            return nil
        }
        var text: String?
        if let string = value as? String {
            text = string
        } else if let data = value as? Data {
            text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
