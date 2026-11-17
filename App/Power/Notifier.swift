import Foundation
import UserNotifications

/// Systémová oznámení o automatickém vypnutí a o výpadku sítě. Když oznámení nejsou povolená
/// nebo dostupná (např. běh mimo .app balíček), tiše nedělá nic.
@MainActor
final class Notifier {
    private let presenter = ForegroundPresenter()
    private var delegateInstalled = false

    init() {}

    /// UNUserNotificationCenter mimo balíček aplikace vyhazuje výjimku.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Zobrazí oznámení; o povolení požádá při první potřebě.
    func post(title: String = String(localized: "Stay Up"), body: String) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if !delegateInstalled {
            center.delegate = presenter
            delegateInstalled = true
        }
        guard await ensureAuthorized(center) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// „Režim Nikdy nevypínat byl vypnut: baterie pod 20 %" apod.
    func postNeverSleepStopped(explanation: String) async {
        await post(body: Self.neverSleepStoppedMessage(explanation: explanation))
    }

    nonisolated static func neverSleepStoppedMessage(explanation: String) -> String {
        String(localized: "Režim Nikdy nevypínat byl vypnut: \(explanation)")
    }

    // MARK: Hlídání sítě

    func postNetworkLost() async {
        await post(body: String(localized: "Mac ztratil připojení k síti"))
    }

    func postNetworkRestored() async {
        await post(body: String(localized: "Připojení je zpět"))
    }

    func postKeepAwakeEndedNoNetwork(minutes: Int) async {
        await post(body: String(localized: "Bdění ukončeno: \(minutes)\u{00A0}min bez připojení"))
    }

    private func ensureAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }
}

/// Dovolí zobrazit banner, i když je aplikace zrovna aktivní (otevřený panel).
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
