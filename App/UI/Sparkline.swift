import SwiftUI

/// Křivka z hodnot 0...1. Body jsou zarovnané vpravo, takže neúplná historie nezačíná smyšlenou hodnotou.
/// Bez `animatableData`: grafy se neanimují (viz `Sparkline`), takže SwiftUI nemusí při každém vzorku
/// porovnávat a interpolovat pole hodnot.
struct SparklineShape: Shape {
    var values: [Double]
    var capacity: Int
    /// Uzavřít k dolnímu okraji (pro výplň pod křivkou).
    var closed = false

    func path(in rect: CGRect) -> Path {
        let all = values
        let slots = max(capacity, 2)
        let visible = all.count > slots ? Array(all.suffix(slots)) : all
        guard visible.count >= 2, rect.width > 0, rect.height > 0 else { return Path() }

        let step = rect.width / CGFloat(slots - 1)
        let firstSlot = slots - visible.count
        let inset: CGFloat = 1
        let height = rect.height - inset * 2
        let points = visible.enumerated().map { index, value in
            let clamped = value.isFinite ? min(max(value, 0), 1) : 0
            return CGPoint(x: rect.minX + CGFloat(firstSlot + index) * step,
                           y: rect.maxY - inset - CGFloat(clamped) * height)
        }

        var path = Path()
        path.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let middle = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: middle, control: previous)
        }
        path.addLine(to: points[points.count - 1])

        if closed {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Malý graf průběhu. Čistě ozdobný; textovou hodnotu pro VoiceOver nese nadřazený řádek.
/// Záměrně bez animace: nový vzorek přichází každou sekundu a plynulý přechod 60 bodů
/// stál několik procent CPU. Graf se posouvá po krocích jako v Monitoru aktivity.
struct Sparkline: View {
    /// Hodnoty 0...1, nejnovější poslední.
    let values: [Double]
    var capacity = MetricsStore.historyCapacity
    var tint: Color = .accentColor

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            SparklineShape(values: values, capacity: capacity, closed: true)
                .fill(tint.opacity(contrast == .increased ? 0.25 : 0.14))
            SparklineShape(values: values, capacity: capacity)
                .stroke(tint, style: StrokeStyle(lineWidth: contrast == .increased ? 2 : 1.5,
                                                 lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Sloupečky vytížení jednotlivých jader (hodnoty 0...1).
struct CoreBarsShape: Shape {
    var values: [Double]
    var spacing: CGFloat = 2

    func path(in rect: CGRect) -> Path {
        let count = values.count
        guard count > 0, rect.width > 0, rect.height > 0 else { return Path() }
        let width = max(1, (rect.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let radius = min(width / 2, 2)
        var path = Path()
        for (index, value) in values.enumerated() {
            let clamped = value.isFinite ? min(max(value, 0), 1) : 0
            let height = max(1.5, rect.height * CGFloat(clamped))
            let bar = CGRect(x: rect.minX + CGFloat(index) * (width + spacing),
                             y: rect.maxY - height, width: width, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}

struct CoreBars: View {
    let values: [Double]
    var tint: Color = .accentColor

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            // Pozadí závisí jen na počtu jader, takže se s novým vzorkem nepřekresluje.
            CoreBarsTrack(count: values.count)
            CoreBarsShape(values: values.map(Self.quantized))
                .fill(tint)
        }
        .accessibilityHidden(true)
    }
}

extension CoreBars {
    /// Krok 1/32 je půl bodu výšky sloupečku. V klidu se tak tvar mezi vzorky nemění
    /// a SwiftUI vrstvu nepřekresluje.
    private static func quantized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(max(value, 0), 1) * 32).rounded() / 32
    }
}

/// Neměnné pozadí sloupečků. Vstupem je jen počet jader, takže ho SwiftUI při novém vzorku přeskočí.
private struct CoreBarsTrack: View {
    let count: Int

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        CoreBarsShape(values: [Double](repeating: 1, count: count))
            .fill(.primary.opacity(contrast == .increased ? 0.18 : 0.08))
    }
}

/// Vyplněná část tenkého ukazatele (kapsle zleva, nejméně 4 body).
private struct ThinBarFill: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let width = min(rect.width, max(4, rect.width * CGFloat(fraction)))
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    cornerRadius: rect.height / 2)
    }
}

/// Tenký ukazatel podílu 0...1.
struct ThinBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        // Tvar místo GeometryReaderu: změna podílu jen překreslí vrstvu, rozvržení se nepočítá.
        Capsule()
            .fill(.primary.opacity(contrast == .increased ? 0.2 : 0.1))
            .overlay { ThinBarFill(fraction: clamped).fill(tint) }
            .frame(height: 4)
        .accessibilityHidden(true)
    }
}
