import SwiftUI

/// Ikona v liště: symbol stavu a využití CPU. Symbol je šablonový, takže je čitelný ve světlé i tmavé liště.
struct MenuBarLabel: View {
    let metrics: MetricsStore
    let sleep: SleepController

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            Text(verbatim: cpuText)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Stay Up"))
        .accessibilityValue(Text(verbatim: accessibilityValue))
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

    private var accessibilityValue: String {
        let state: String
        if sleep.neverSleepOn {
            state = String(localized: "Režim Nikdy nevypínat je zapnutý")
        } else if sleep.keepAwakeOn {
            state = String(localized: "Mac běží, displej může zhasnout")
        } else {
            state = String(localized: "Mac usíná podle nastavení systému")
        }
        guard let percent = metrics.menuBarCPUPercent else { return state }
        return state + ", " + String(localized: "CPU \(percent)\u{00A0}%")
    }
}
