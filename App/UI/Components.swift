import AppKit
import CoreLocation
import Observation
import SwiftUI

// MARK: - Karta ze skla

/// Karta z Liquid Glass. Při omezené průhlednosti neprůhledná, při vyšším kontrastu s výrazným okrajem.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    /// Jemné zabarvení skla (např. když je režim zapnutý).
    var tint: Color?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay {
                    shape.strokeBorder((tint ?? Color.primary).opacity(contrast == .increased ? 0.8 : 0.3),
                                       lineWidth: contrast == .increased ? 1.5 : 1)
                }
        } else {
            content
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular,
                             in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(.primary.opacity(0.55), lineWidth: 1)
                    }
                }
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tint: tint))
    }
}

/// Barva vedlejšího textu; při vyšším kontrastu plná.
struct SecondaryText: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
}

extension View {
    func secondaryText() -> some View { modifier(SecondaryText()) }
}

// MARK: - Text, který nehýbe rozvržením

/// Jednořádkový text pro hodnoty, které se mění každou sekundu. Místo v rozvržení drží neviditelný
/// vzor (výška řádku, zbylá šířka) a hodnota se kreslí v překryvu nad ním. Změna hodnoty tak
/// nezmění velikost ničeho kolem a SwiftUI nemusí při každém vzorku přepočítat rozvržení celého
/// panelu – jen překreslí tento text. Písmo se nastavuje zvenčí a platí pro vzor i hodnotu.
/// Příliš dlouhý text se zkrátí výpustkou.
struct SteadyText: View {
    let text: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        Text(verbatim: "0")
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay(alignment: Alignment(horizontal: alignment, vertical: .firstTextBaseline)) {
                Text(verbatim: text)
                    .lineLimit(1)
            }
    }
}

// MARK: - Viditelnost okna panelu

/// Hlásí změny viditelnosti okna, ve kterém leží (pojistka k onAppear/onDisappear panelu).
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        nsView.onChange = onChange
    }
}

final class WindowTrackingView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        // Selektorové pozorování se při zániku pohledu odhlásí samo.
        center.addObserver(self, selector: #selector(occlusionChanged(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        guard let window else { return }
        onChange?(window.occlusionState.contains(.visible))
    }
}

// MARK: - Oprávnění k poloze (název Wi-Fi sítě)

/// macOS vydá název Wi-Fi sítě jen aplikaci s přístupem k poloze. O oprávnění se žádá
/// výhradně po klepnutí uživatele; polohu samotnou aplikace nikdy nečte.
@MainActor
@Observable
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    enum Status: Sendable {
        case unknown
        case notDetermined
        case denied
        case authorized
    }

    private(set) var status: Status = .unknown

    @ObservationIgnored private var manager: CLLocationManager?

    /// Zjistí aktuální stav oprávnění (o nic nežádá).
    func refresh() {
        let current = Self.map(ensureManager().authorizationStatus)
        if status != current { status = current }
    }

    /// Zobrazí systémovou žádost o přístup k poloze.
    func request() {
        let manager = ensureManager()
        NSApp.activate()
        manager.requestWhenInUseAuthorization()
    }

    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let created = CLLocationManager()
        created.delegate = self
        manager = created
        return created
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let raw = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            let current = Self.map(raw)
            if self.status != current { self.status = current }
        }
    }

    private nonisolated static func map(_ status: CLAuthorizationStatus) -> Status {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted, .denied: .denied
        case .authorizedAlways, .authorizedWhenInUse, .authorized: .authorized
        @unknown default: .unknown
        }
    }
}
