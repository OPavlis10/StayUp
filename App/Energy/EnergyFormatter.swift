import Foundation

/// Texty pro modul Energie. Čisté funkce, české národní prostředí (desetinná čárka,
/// nezlomitelná mezera před jednotkou). Jednotky W, h, min a % jsou stejné ve všech jazycích.
enum EnergyFormatter {
    private static let space = "\u{00A0}"

    /// Příkon, např. „8,4 W"; od 100 W bez desetinného místa („140 W").
    static func watts(_ value: Double, fractionDigits: Int? = nil, locale: Locale = MetricsFormatter.czech) -> String {
        let watts = value.isFinite ? max(value, 0) : 0
        let digits = fractionDigits ?? (watts < 99.95 ? 1 : 0)
        return watts.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + space + "W"
    }

    /// Příkon jednoho procesu: pod 0,05 W „<0,1 W" místo zavádějícího „0,0 W".
    static func processWatts(_ value: Double, locale: Locale = MetricsFormatter.czech) -> String {
        guard value.isFinite, value >= 0.05 else { return "<" + watts(0.1, fractionDigits: 1, locale: locale) }
        return watts(value, locale: locale)
    }

    /// Využití CPU v procentech jednoho jádra, např. „3,4 %", „12 %", „240 %".
    static func cpuPercent(_ percent: Double, locale: Locale = MetricsFormatter.czech) -> String {
        let value = percent.isFinite ? max(percent, 0) : 0
        let digits = value < 9.95 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + space + "%"
    }

    /// Doba v minutách, např. „3 h 20 min", „2 h", „45 min".
    static func duration(minutes: Int) -> String {
        let total = max(minutes, 0)
        let hours = total / 60
        let rest = total % 60
        if hours == 0 { return "\(rest)\(space)min" }
        if rest == 0 { return "\(hours)\(space)h" }
        return "\(hours)\(space)h\(space)\(rest)\(space)min"
    }
}
