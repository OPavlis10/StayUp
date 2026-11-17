import Foundation
import Observation

/// Co o sledovaných procesech ukázat v panelu. Hotové hodnoty: mění se nejvýš jednou za vzorek
/// a nezměněná hodnota se znovu nezapisuje, takže zbytečně nepřekresluje zobrazení.
enum AIActivityStatus: Sendable, Equatable {
    /// Ještě není s čím porovnat (první vzorek, změna nastavení).
    case measuring
    /// Sledované procesy pracují; `names` jsou nejvytíženější z nich.
    case working(names: String)
    /// Procesy běží, ale nepracují už `minutes` z `limit` minut.
    case idle(minutes: Int, limit: Int)
    /// Žádný sledovaný proces neběží.
    case noProcess(minutes: Int, limit: Int)
}

/// „Bdít, jen dokud AI pracuje": vlastní sledovač procesů, počítadlo nečinnosti a jedinou smyčku.
/// Smyčka existuje jen mezi `start` a `stop`; jinak neběží nic. O tom, kdy má běžet, rozhoduje
/// `AppModel` (zapnutý přepínač spánku a zapnutá volba v nastavení).
@MainActor
@Observable
final class AIActivityMonitor {
    /// `nil`, když sledování neběží.
    private(set) var status: AIActivityStatus?

    /// Nečinnost trvala nastavenou dobu (v minutách). Sledování je v tu chvíli už zastavené.
    @ObservationIgnored var onExpired: (@MainActor (_ minutes: Int) -> Void)?

    @ObservationIgnored private let watcher = ActivityWatcher()
    @ObservationIgnored private var tracker = IdleTracker()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    private static let interval: Duration = .seconds(15)

    var isRunning: Bool { task != nil }

    /// Začne sledovat od nuly. Opakované volání začne znovu.
    func start(patterns: [String], thresholdPercent: Int, minutes: Int) {
        task?.cancel()
        generation += 1
        let id = generation
        tracker = IdleTracker(minutes: minutes)
        tracker.start(at: ActivityClock.uptime())
        publish(.measuring)
        task = Task { [weak self, watcher] in
            await watcher.configure(patterns: patterns, thresholdPercent: Double(thresholdPercent))
            await watcher.reset()
            _ = await watcher.sample()   // výchozí stav počítadel; práci ještě neumí posoudit
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.interval, tolerance: .seconds(3)) } catch { return }
                guard let sample = await watcher.sample() else { continue }
                guard !Task.isCancelled, let self, self.generation == id else { return }
                if self.record(sample) { return }
            }
        }
    }

    func stop() {
        guard task != nil else { return }
        halt()
        Task { [watcher] in await watcher.reset() }
    }

    /// Uživatel zapnul další přepínač: nečinnost se počítá znovu od teď.
    func restartCountdown() {
        guard task != nil else { return }
        tracker.start(at: ActivityClock.uptime())
        publish(.measuring)
    }

    /// Změna nastavení za běhu. Nasbíraná nečinnost zůstává; změna vzorů zahodí výchozí stav počítadel.
    func update(patterns: [String], thresholdPercent: Int, minutes: Int) {
        guard task != nil else { return }
        tracker.setMinutes(minutes)
        Task { [watcher] in
            await watcher.configure(patterns: patterns, thresholdPercent: Double(thresholdPercent))
        }
    }

    // MARK: - Vnitřek

    private func halt() {
        task?.cancel()
        task = nil
        generation += 1
        publish(nil)
    }

    /// Zapíše vzorek. Vrací `true`, když nečinnost vypršela (sledování se tím zastaví).
    private func record(_ sample: ActivitySample) -> Bool {
        let limit = Int(tracker.requiredIdle / 60)
        guard !tracker.record(sample) else {
            halt()
            onExpired?(limit)
            return true
        }
        let idleMinutes = Int(tracker.idleDuration / 60)
        switch sample.isWorking {
        case .none:
            publish(.measuring)
        case .some(true):
            publish(.working(names: Self.displayNames(sample.topGroups)))
        case .some(false):
            publish(sample.matchedCount == 0
                    ? .noProcess(minutes: idleMinutes, limit: limit)
                    : .idle(minutes: idleMinutes, limit: limit))
        }
        return false
    }

    private func publish(_ new: AIActivityStatus?) {
        if status != new { status = new }
    }

    /// Nejvýš dva názvy pro řádek v panelu: pomocné procesy („Claude Helper (Renderer)") se
    /// ukážou pod názvem své aplikace a stejné názvy lišící se jen velikostí písmen jednou
    /// (vždy ve stejné podobě). Kromě první skupiny se uvádějí jen ty, které opravdu pracují.
    private static func displayNames(_ groups: [ActivityProcessGroup]) -> String {
        var order: [String] = []
        var shown: [String: String] = [:]
        for group in groups {
            var name = group.name
            if let helper = name.range(of: " Helper") { name = String(name[..<helper.lowerBound]) }
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            if let existing = shown[key] {
                if name < existing { shown[key] = name }   // „Claude" < „claude": velké písmeno má přednost
            } else if order.isEmpty || (group.cpuPercent ?? 0) >= 0.5 {
                order.append(key)
                shown[key] = name
            }
        }
        return order.prefix(2).compactMap { shown[$0] }.joined(separator: ", ")
    }
}
