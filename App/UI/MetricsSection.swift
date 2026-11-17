import SwiftUI

/// Přehled systému. Každý řádek čte jen svou metriku, takže se překresluje samostatně.
struct MetricsSection: View {
    let metrics: MetricsStore
    let location: LocationPermission
    let watch: NetworkWatch

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CPURow(metrics: metrics)
            MemoryRow(metrics: metrics)
            DiskRow(metrics: metrics)
            GPURow(metrics: metrics)
            NetworkRow(metrics: metrics, location: location, watch: watch)
        }
    }
}

/// Text pro chybějící údaj.
var unavailableText: String { String(localized: "nedostupné") }

// MARK: - Společná hlavička řádku

struct MetricHeader: View {
    let symbol: String
    let title: LocalizedStringKey
    /// `nil` = údaj není k dispozici.
    let value: String?
    var numeric = false
    /// Hodnota jako vedlejší text (popisek, ne měřený údaj).
    var dimmed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .secondaryText()
                .frame(width: 16)
            Text(title)
                .font(.subheadline.weight(.medium))
                .fixedSize()
            // Hodnota zabírá zbytek řádku a je zarovnaná vpravo; viz `SteadyText`.
            Group {
                if let value, dimmed {
                    SteadyText(text: value, alignment: .trailing)
                        .secondaryText()
                } else if let value {
                    // Bez animace číslic: hodnota se mění každou sekundu a přechod numericText
                    // (rozmazání vykreslované procesorem) stál sám několik procent CPU.
                    SteadyText(text: value, alignment: .trailing)
                        .monospacedDigit()
                } else {
                    SteadyText(text: unavailableText, alignment: .trailing)
                        .secondaryText()
                }
            }
            .font(.subheadline)
            .padding(.leading, 2)
        }
    }
}

// MARK: - CPU

private struct CPURow: View {
    let metrics: MetricsStore

    var body: some View {
        let cpu = metrics.cpu
        VStack(alignment: .leading, spacing: 6) {
            MetricHeader(symbol: "cpu", title: "CPU",
                         value: cpu.map { MetricsFormatter.percent($0.total) }, numeric: true)
            Sparkline(values: metrics.cpuHistory)
                .frame(height: 28)
            if let cores = cpu?.perCore, !cores.isEmpty {
                CoreBars(values: cores)
                    .frame(height: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("CPU"))
        .accessibilityValue(Text(verbatim: accessibilityValue(cpu)))
    }

    private func accessibilityValue(_ cpu: CPUMetrics?) -> String {
        guard let cpu else { return unavailableText }
        let total = MetricsFormatter.percent(cpu.total)
        guard let busiest = cpu.perCore.max() else {
            return String(localized: "Využití \(total)")
        }
        // Počet jader jako hotový text: celé číslo vložené přímo by se při každém vzorku formátovalo
        // podle národního prostředí, což je řádově dražší než zbytek řádku.
        return String(localized: "Využití \(total), počet jader: \(String(cpu.perCore.count)), nejvytíženější jádro \(MetricsFormatter.percent(busiest))")
    }
}

// MARK: - Paměť

private struct MemoryRow: View {
    let metrics: MetricsStore

    var body: some View {
        let memory = metrics.memory
        VStack(alignment: .leading, spacing: 6) {
            MetricHeader(symbol: "memorychip", title: "Paměť", value: memory?.usedText)
            if let memory {
                ThinBar(fraction: memory.usedFraction,
                        tint: PressureBadge.color(for: memory.pressure))
                HStack(alignment: .center, spacing: 12) {
                    SteadyText(text: memory.detailText)
                        .font(.caption)
                        .monospacedDigit()
                        .secondaryText()
                        .minimumScaleFactor(0.85)
                    if let pressure = memory.pressure {
                        PressureBadge(pressure: pressure)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Paměť"))
        .accessibilityValue(Text(verbatim: accessibilityValue(memory)))
    }

    private func accessibilityValue(_ memory: MemoryDisplay?) -> String {
        guard let memory else { return unavailableText }
        var parts = [
            String(localized: "Využito \(memory.usedText)"),
            memory.detailText,
        ]
        if let pressure = memory.pressure {
            parts.append(String(localized: "Tlak paměti: \(PressureBadge.name(for: pressure))"))
        }
        return parts.joined(separator: ", ")
    }
}

extension MemoryDisplay {
    /// Texty vznikají jednou při příchodu vzorku (ne při každém překreslení řádku).
    init(_ memory: MemoryMetrics) {
        usedText = String(localized: "\(MetricsFormatter.bytes(memory.used, binary: true)) z \(MetricsFormatter.bytes(memory.total, binary: true))")
        detailText = String(localized: "Volné \(MetricsFormatter.bytes(memory.free, binary: true)) · Komprimované \(MetricsFormatter.bytes(memory.compressed, binary: true))")
        // Ukazatel je široký zhruba 300 bodů; jemnější krok než 1/400 by nebyl vidět.
        let fraction = memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0
        usedFraction = (min(max(fraction, 0), 1) * 400).rounded() / 400
        pressure = memory.pressure
    }
}

/// Tlak paměti jako barevná kapsle s textem (barva není jediný nositel informace).
private struct PressureBadge: View {
    let pressure: MemoryPressure

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let color = Self.color(for: pressure)
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(verbatim: Self.name(for: pressure))
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(contrast == .increased ? 0.3 : 0.16), in: Capsule())
        .overlay {
            Capsule().strokeBorder(color.opacity(contrast == .increased ? 0.9 : 0.35), lineWidth: 1)
        }
        .help(Text("Tlak paměti"))
    }

    static func name(for pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Normální")
        case .warning: String(localized: "Zvýšený")
        case .critical: String(localized: "Kritický")
        }
    }

    static func color(for pressure: MemoryPressure?) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        case nil: .accentColor
        }
    }
}

// MARK: - Disk

private struct DiskRow: View {
    let metrics: MetricsStore

    var body: some View {
        let disk = metrics.disk
        VStack(alignment: .leading, spacing: 6) {
            MetricHeader(symbol: "internaldrive", title: "Disk", value: disk.map(usedText))
            if let disk {
                ThinBar(fraction: disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0)
                Text(verbatim: freeText(disk))
                    .font(.caption)
                    .monospacedDigit()
                    .secondaryText()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Disk"))
        .accessibilityValue(Text(verbatim: disk.map {
            String(localized: "Využito \(usedText($0))") + ", " + freeText($0)
        } ?? unavailableText))
    }

    private func usedText(_ disk: DiskMetrics) -> String {
        String(localized: "\(MetricsFormatter.bytes(disk.used)) z \(MetricsFormatter.bytes(disk.total))")
    }

    private func freeText(_ disk: DiskMetrics) -> String {
        String(localized: "Volné \(MetricsFormatter.bytes(disk.free))")
    }
}

// MARK: - GPU

private struct GPURow: View {
    let metrics: MetricsStore

    var body: some View {
        let gpu = metrics.gpu
        VStack(alignment: .leading, spacing: 4) {
            MetricHeader(symbol: "cube.transparent", title: "GPU",
                         value: gpu.map { MetricsFormatter.percent($0.utilization) }, numeric: true)
            if let gpu {
                ThinBar(fraction: gpu.utilization)
                if let name = gpu.name {
                    Text(verbatim: name)
                        .font(.caption)
                        .secondaryText()
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("GPU"))
        .accessibilityValue(Text(verbatim: accessibilityValue(gpu)))
    }

    private func accessibilityValue(_ gpu: GPUMetrics?) -> String {
        guard let gpu else { return unavailableText }
        let usage = String(localized: "Využití \(MetricsFormatter.percent(gpu.utilization))")
        return gpu.name.map { usage + ", " + $0 } ?? usage
    }
}

// MARK: - Síť

private struct NetworkRow: View {
    let metrics: MetricsStore
    let location: LocationPermission
    /// Hlídání sítě (běží jen při zapnutém bdění); když hlásí, že cesta není, má přednost.
    let watch: NetworkWatch

    var body: some View {
        let network = metrics.network
        let offline = watch.path.map { !$0.isUsable } ?? false
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                MetricHeader(symbol: "network", title: "Síť",
                             value: offline ? Self.offlineText : network.flatMap(Self.networkName))
                if let network {
                    HStack(alignment: .top, spacing: 12) {
                        RateColumn(symbol: "arrow.down", rate: network.downloadBytesPerSecond,
                                   history: metrics.downloadHistory, tint: .blue)
                        RateColumn(symbol: "arrow.up", rate: network.uploadBytesPerSecond,
                                   history: metrics.uploadHistory, tint: .purple)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Síť"))
            .accessibilityValue(Text(verbatim: accessibilityValue(network, offline: offline)))

            // Tlačítko zůstává samostatným prvkem, aby šlo ovládat i z VoiceOveru.
            // Jen na Wi-Fi: jinde by oprávnění k poloze žádný název nepřineslo.
            if let network, network.wifiActive, network.ssid == nil, !offline {
                SSIDPermissionHint(location: location)
            }
        }
    }

    /// Název sítě do hlavičky. `nil` („nedostupné") jen tehdy, když je Wi-Fi aktivní a název skrytý.
    private static func networkName(_ network: NetworkMetrics) -> String? {
        if let ssid = network.ssid { return ssid }
        if network.wifiActive { return nil }
        guard let interface = network.primaryInterface else { return offlineText }
        // Fyzická rozhraní mimo Wi-Fi se jmenují enN; jiná (např. VPN) se ukážou svým názvem.
        return interface.hasPrefix("en") ? String(localized: "Ethernet") : interface
    }

    private static var offlineText: String { String(localized: "bez připojení") }

    private func accessibilityValue(_ network: NetworkMetrics?, offline: Bool) -> String {
        guard let network else { return offline ? Self.offlineText : unavailableText }
        let name = offline ? Self.offlineText : Self.networkName(network) ?? unavailableText
        return [
            String(localized: "Název sítě: \(name)"),
            String(localized: "Stahování \(MetricsFormatter.rate(network.downloadBytesPerSecond))"),
            String(localized: "Odesílání \(MetricsFormatter.rate(network.uploadBytesPerSecond))"),
        ].joined(separator: ", ")
    }
}

private struct RateColumn: View {
    let symbol: String
    let rate: Double
    let history: [Double]
    let tint: Color

    var body: some View {
        let text = MetricsFormatter.rate(rate)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                SteadyText(text: text)
                    .font(.caption)
                    .monospacedDigit()
            }
            Sparkline(values: normalized, tint: tint)
                .frame(height: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Měřítko podle maxima v historii; spodní mez 10 kB/s, aby klidový šum nevypadal jako provoz.
    private var normalized: [Double] {
        let peak = max(history.max() ?? 0, 10_000)
        return history.map { $0 / peak }
    }
}

/// Nabídka povolit název sítě. O oprávnění se žádá až po klepnutí.
private struct SSIDPermissionHint: View {
    let location: LocationPermission

    var body: some View {
        switch location.status {
        case .notDetermined:
            VStack(alignment: .leading, spacing: 4) {
                Button("Povolit název sítě") {
                    location.request()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(Text("macOS sdělí název Wi‑Fi sítě jen aplikacím s přístupem k poloze. Stay Up polohu nečte ani nikam neodesílá."))
                Text("macOS k tomu vyžaduje přístup k poloze. Stay Up ji nečte ani neodesílá.")
                    .font(.caption2)
                    .secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .denied:
            Text("Název sítě je skrytý, protože Stay Up nemá přístup k poloze. Povolit ho můžete v Nastavení systému › Soukromí a zabezpečení › Polohové služby.")
                .font(.caption2)
                .secondaryText()
                .fixedSize(horizontal: false, vertical: true)
        case .authorized, .unknown:
            EmptyView()
        }
    }
}
