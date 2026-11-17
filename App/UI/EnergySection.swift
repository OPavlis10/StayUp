import SwiftUI

/// „Kdo žere energii": tři nejnáročnější aplikace. Měří se jen při otevřeném panelu, zhruba každých
/// 5 s. Řádky jsou vždy tři a mají pevné sloupce, takže se při změně hodnot nemění rozvržení.
struct EnergySection: View {
    let metrics: MetricsStore

    private static let rowCount = 3

    var body: some View {
        let display = metrics.topProcesses
        VStack(alignment: .leading, spacing: 6) {
            MetricHeader(symbol: "flame", title: "Kdo žere energii", value: headerValue(display), dimmed: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Kdo žere energii"))
                .accessibilityValue(Text(verbatim: accessibilityNote(display)))
                .accessibilityAddTraits(.isHeader)
                .help(Text("Jen procesy tohoto uživatele, bez systémových. Sloupce: využití procesoru a odhad jeho příkonu."))

            VStack(spacing: 3) {
                ForEach(0..<Self.rowCount, id: \.self) { index in
                    ProcessRow(row: display.flatMap { index < $0.rows.count ? $0.rows[index] : nil })
                        .equatable()
                }
            }
        }
    }

    /// Vpravo v hlavičce: stav měření, potom poctivá poznámka o tom, čí procesy seznam obsahuje.
    /// Aplikace běží pod přihlášeným uživatelem; cizí a systémové procesy jí systém nevydá.
    private func headerValue(_ display: TopProcessesDisplay?) -> String {
        guard let display else { return String(localized: "Měřím…") }
        if display.rows.isEmpty { return String(localized: "Nic výrazného neběží") }
        return display.isLimitedToCurrentUser ? String(localized: "jen vaše procesy") : ""
    }

    private func accessibilityNote(_ display: TopProcessesDisplay?) -> String {
        guard let display, !display.rows.isEmpty else { return headerValue(display) }
        return display.isLimitedToCurrentUser ? String(localized: "Jen procesy tohoto uživatele, bez systémových.") : ""
    }
}

private struct ProcessRow: View, Equatable {
    let row: TopProcessesDisplay.Row?

    var body: some View {
        HStack(spacing: 8) {
            SteadyText(text: row?.name ?? "")
            SteadyText(text: row?.cpuText ?? "", alignment: .trailing)
                .monospacedDigit()
                .frame(width: 50)
            SteadyText(text: row?.powerText ?? "", alignment: .trailing)
                .monospacedDigit()
                .secondaryText()
                .frame(width: 50)
                .help(Text("Odhad příkonu procesoru"))
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row?.name ?? ""))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHidden(row == nil)
    }

    private var accessibilityValue: String {
        guard let row else { return "" }
        let cpu = String(localized: "CPU \(row.cpuText)")
        guard let power = row.powerText else { return cpu }
        return cpu + ", " + String(localized: "odhad příkonu \(power)")
    }
}

// MARK: - Příkon a výdrž

/// Jeden řádek: příkon počítače a výdrž baterie, ze sítě stav nabíjení a adaptér.
struct PowerDrawRow: View {
    let metrics: MetricsStore

    var body: some View {
        let line = metrics.powerLine
        MetricHeader(symbol: "bolt", title: "Příkon", value: line)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Příkon a výdrž"))
            .accessibilityValue(Text(verbatim: line ?? unavailableText))
    }
}

extension PowerDrawDisplay {
    /// Např. „8,4 W · zbývá asi 3 h 20 min" nebo „16,8 W · nenabíjí se · adaptér 60 W".
    /// `nil`, když není co ukázat. Vzniká jednou při příchodu vzorku, ne při překreslení.
    var summaryLine: String? {
        var parts: [String] = []
        if let systemText { parts.append(systemText) }
        if isOnAC {
            if isCharging {
                parts.append(String(localized: "nabíjí se"))
                if let toFullText {
                    parts.append(String(localized: "do nabití \(toFullText)"))
                } else if let adapterRatedText {
                    parts.append(String(localized: "adaptér \(adapterRatedText)"))
                }
            } else {
                parts.append(isFullyCharged ? String(localized: "nabito") : String(localized: "nenabíjí se"))
                if let adapterRatedText { parts.append(String(localized: "adaptér \(adapterRatedText)")) }
            }
        } else {
            switch timeRemaining {
            case .minutes(_, source: .system):
                if let remainingText { parts.append(String(localized: "zbývá \(remainingText)")) }
            case .minutes(_, source: .estimated):
                if let remainingText { parts.append(String(localized: "zbývá asi \(remainingText)")) }
            case .unknown:
                parts.append(String(localized: "výdrž se počítá…"))
            case .unlimited:
                break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
