import Foundation

/// Jak dlouho mají přepínače zůstat zapnuté.
enum AwakeDuration: String, CaseIterable, Sendable, Identifiable {
    case oneHour
    case twoHours
    case fourHours
    case untilOff

    var id: String { rawValue }

    /// Český popisek do nabídky.
    var label: String {
        switch self {
        case .oneHour: String(localized: "1 hodina")
        case .twoHours: String(localized: "2 hodiny")
        case .fourHours: String(localized: "4 hodiny")
        case .untilOff: String(localized: "Do vypnutí")
        }
    }

    /// Délka v sekundách; `nil` znamená bez časového limitu.
    var seconds: TimeInterval? {
        switch self {
        case .oneHour: 3_600
        case .twoHours: 7_200
        case .fourHours: 14_400
        case .untilOff: nil
        }
    }
}
