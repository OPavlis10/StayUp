import SwiftUI

/// Ikona v liště: symbol stavu a využití CPU. Symbol je šablonový, takže je čitelný ve světlé i tmavé liště.
/// S volbou „V liště jen ikona" zůstane jen symbol; číslo CPU se pak vůbec nečte, takže se položka
/// překreslí jen při změně stavu přepínačů.
struct MenuBarLabel: View {
    let metrics: MetricsStore
    let sleep: SleepController
    let settings: AppSettings

    var body: some View {
        let iconOnly = settings.menuBarIconOnly
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            if !iconOnly {
                Text(verbatim: cpuText)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Stay Up"))
        .accessibilityValue(Text(verbatim: iconOnly ? stateDescription : accessibilityValue))
    }

    /// Režim B má vlastní výrazný symbol, režim A decentnější, klid jen čip.
    private var symbolName: String {
        if sleep.neverSleepOn { return "bolt.shield.fill" }
        if sleep.keepAwakeOn { return "cup.and.saucer.fill" }
        return "cpu"
    }

    /// Vždy dvě místa, aby šířka neposkakovala: jednociferná hodnota i pomlčka se doplní číslicovou
    /// mezerou a 100 se ukáže jako 99 (přesnou hodnotu má VoiceOver).
    private var cpuText: String {
        guard let percent = metrics.menuBarCPUPercent else { return "\u{2007}–\u{00A0}%" }
        let shown = min(percent, 99)
        let padding = shown < 10 ? "\u{2007}" : ""
        return "\(padding)\(shown)\u{00A0}%"
    }

    private var stateDescription: String {
        if sleep.neverSleepOn { return String(localized: "Režim Nikdy nevypínat je zapnutý") }
        if sleep.keepAwakeOn { return String(localized: "Mac běží, displej může zhasnout") }
        return String(localized: "Mac usíná podle nastavení systému")
    }

    private var accessibilityValue: String {
        let state = stateDescription
        guard let percent = metrics.menuBarCPUPercent else { return state }
        return state + ", " + String(localized: "CPU \(percent)\u{00A0}%")
    }
}
