import Foundation

/// Převod čísel na text pro zobrazení. Čisté funkce, bez stavu.
/// Výchozí je české národní prostředí (desetinná čárka, mezera před jednotkou).
enum MetricsFormatter {
    static let czech = Locale(identifier: "cs_CZ")

    /// Nezlomitelná mezera mezi číslem a jednotkou.
    private static let space = "\u{00A0}"

    /// Velikost v bajtech, např. „12,4 GB". `binary: true` (1 GB = 1024³ B) pro paměť,
    /// `false` (1 GB = 10⁹ B) pro disk – stejně jako Monitor aktivity a Finder.
    static func bytes(_ value: UInt64, binary: Bool = false, locale: Locale = czech) -> String {
        scaled(Double(value), step: binary ? 1024 : 1000, units: ["B", "kB", "MB", "GB", "TB", "PB"], firstUnit: 0, locale: locale)
    }

    /// Rychlost přenosu z bajtů za sekundu, např. „850 kB/s" nebo „1,2 MB/s". Nejmenší jednotka je kB/s.
    static func rate(_ bytesPerSecond: Double, locale: Locale = czech) -> String {
        let value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        return scaled(value, step: 1000, units: ["B/s", "kB/s", "MB/s", "GB/s"], firstUnit: 1, locale: locale)
    }

    /// Podíl 0...1 jako procenta, např. „42 %".
    static func percent(_ fraction: Double, fractionDigits: Int = 0, locale: Locale = czech) -> String {
        let value = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return value.formatted(.percent.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    /// Desetinné místo jen od MB výš a jen pod 100, aby text zůstal krátký.
    private static func scaled(_ value: Double, step: Double, units: [String], firstUnit: Int, locale: Locale) -> String {
        var scaledValue = value / pow(step, Double(firstUnit))
        var index = firstUnit
        // 999,5 a víc by se zaokrouhlilo na 1000 – raději rovnou vyšší jednotka.
        while scaledValue >= step - 0.5, index < units.count - 1 {
            scaledValue /= step
            index += 1
        }
        let digits = index >= 2 && scaledValue < 99.95 ? 1 : 0
        let number = scaledValue.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        return number + space + units[index]
    }
}
