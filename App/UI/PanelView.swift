import AppKit
import SwiftUI

/// Obsah okna pod ikonou v liště.
struct PanelView: View {
    let model: AppModel

    @State private var showsSettings = false
    /// Výška hlavičky; mění se jen při změně obsahu, ne s každým vzorkem.
    @State private var headerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(sleep: model.sleep, showsSettings: $showsSettings)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            // Běžně se obsah vejde celý. Jen na malé obrazovce (nebo při větším textu) by spodek
            // přetekl mimo displej; pak se použije posuvná varianta, viz `FitOrScroll`.
            if showsSettings {
                FitOrScroll(available: availableHeight) {
                    SettingsView(settings: model.settings)
                }
                .transition(.opacity)
            } else {
                FitOrScroll(available: availableHeight) {
                    overview
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: 340)
        .frame(maxHeight: Self.maxHeight)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: showsSettings)
        .background(WindowVisibilityReader { visible in model.setPanelOpen(visible) })
        .onAppear { model.setPanelOpen(true) }
        .onDisappear {
            model.setPanelOpen(false)
            showsSettings = false
        }
    }
}

extension PanelView {
    /// Panel nesmí být vyšší než viditelná část obrazovky pod řádkem nabídek.
    private static var maxHeight: CGFloat {
        max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 12)
    }

    /// Součet okrajů panelu (2 × 14) a mezery mezi hlavičkou a obsahem.
    private static let chromeHeight: CGFloat = 28 + 12

    /// Kolik místa zbývá pod hlavičkou.
    private var availableHeight: CGFloat {
        Self.maxHeight - headerHeight - Self.chromeHeight
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            SleepSection(sleep: model.sleep, settings: model.settings,
                         activity: model.aiActivity, network: model.network)
            Divider()
            MetricsSection(metrics: model.metrics, location: model.location, watch: model.network)
            Divider()
            EnergySection(metrics: model.metrics)
            PowerFooter(sleep: model.sleep, metrics: model.metrics)
        }
    }
}

/// Obsah ve své přirozené výšce; když je vyšší než dostupné místo, dá se posouvat. Rozhoduje se
/// podle změřené výšky, ne přes ViewThatFits: ten držel obsah v grafu dvakrát a obě varianty
/// přeměřoval při každém vzorku. Výška se mění jen při změně obsahu, ne s každým vzorkem.
private struct FitOrScroll<Content: View>: View {
    let available: CGFloat
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if contentHeight > 0 && contentHeight > available {
            ScrollView(.vertical) { measured }
                .scrollIndicators(.automatic)
        } else {
            measured
        }
    }

    /// Obsah se nenechá zmáčknout, aby měření platilo v obou variantách.
    private var measured: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
}

// MARK: - Hlavička

private struct PanelHeader: View {
    let sleep: SleepController
    @Binding var showsSettings: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbolName)
                .font(.title2)
                .foregroundStyle(sleep.neverSleepOn ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                .frame(width: 30)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Stay Up")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .secondaryText()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 4)

            Button {
                showsSettings.toggle()
            } label: {
                Image(systemName: showsSettings ? "chevron.backward" : "gearshape")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(showsSettings ? Text("Zpět na přehled") : Text("Nastavení"))
            .accessibilityLabel(showsSettings ? Text("Zpět na přehled") : Text("Nastavení"))

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(Text("Ukončit Stay Up"))
            .accessibilityLabel(Text("Ukončit Stay Up"))
        }
    }

    private var symbolName: String {
        if sleep.neverSleepOn { return "bolt.shield.fill" }
        if sleep.keepAwakeOn { return "cup.and.saucer.fill" }
        return "moon.zzz"
    }

    private var summary: LocalizedStringKey {
        if sleep.neverSleepOn { return "Mac neusne, ani když zavřete víko" }
        if sleep.keepAwakeOn { return "Mac běží, displej může zhasnout" }
        return "Mac usíná podle nastavení systému"
    }
}

// MARK: - Baterie a teplota

private struct PowerFooter: View {
    let sleep: SleepController
    let metrics: MetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Příkon a výdrž čte baterii; Mac bez baterie řádek nemá.
            if sleep.hasBattery {
                PowerDrawRow(metrics: metrics)
            }
            status
        }
    }

    private var status: some View {
        HStack(spacing: 12) {
            if let battery = batteryText {
                Label {
                    Text(verbatim: battery)
                } icon: {
                    Image(systemName: sleep.isOnBattery ? "battery.50percent" : "battery.100percent.bolt")
                }
            }
            Label {
                Text(verbatim: thermalText)
            } icon: {
                Image(systemName: "thermometer.medium")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .secondaryText()
        .accessibilityElement(children: .combine)
    }

    /// Bez baterie (nebo bez údaje) se řádek o baterii nezobrazí.
    private var batteryText: String? {
        guard sleep.hasBattery else { return nil }
        let source = sleep.isOnBattery
            ? String(localized: "na baterii")
            : String(localized: "napájení ze sítě")
        guard let percent = sleep.batteryPercent else {
            return String(localized: "Baterie: \(source)")
        }
        return String(localized: "Baterie \(percent)\u{00A0}%, \(source)")
    }

    private var thermalText: String {
        switch sleep.thermalState {
        case .nominal: String(localized: "Teplota: normální")
        case .fair: String(localized: "Teplota: mírně zvýšená")
        case .serious: String(localized: "Teplota: vážná")
        case .critical: String(localized: "Teplota: kritická")
        @unknown default: String(localized: "Teplota: nedostupné")
        }
    }
}
