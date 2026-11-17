import AppKit

/// Jak byla aplikace spuštěna: běžně, nebo zkušebně (testy a náhledy rozvržení).
/// Zkušební spuštění nesahá na skutečné nastavení ani na pomocný proces a smí běžet vedle
/// běžící aplikace.
enum LaunchMode {
    /// Název oddělené sady nastavení pro zkušební spuštění.
    static let diagnosticSuiteName = "cz.stayup.StayUp.diagnostic"

    /// Argumenty, které dělají ze spuštění zkušební. Snímek panelu a automatické otevření
    /// existují jen v ladicím sestavení (Debug v Xcode, `./build.sh debug`).
    private static let diagnosticArguments: Set<String> = {
        var arguments: Set<String> = ["--selftest", "--selftest-assertion", "--preview-window"]
        #if DEBUG
        arguments.formUnion(["--snapshot", "--auto-open"])
        #endif
        return arguments
    }()

    static let isDiagnostic: Bool = !diagnosticArguments.isDisjoint(with: CommandLine.arguments)

    /// PID jiné běžící instance téže aplikace (stejný bundle identifier), pokud nějaká je.
    /// Nerozliší běžnou instanci od zkušební; o druhém spuštění proto rozhoduje `claimSingleInstance`.
    @MainActor
    static func otherRunningInstance() -> pid_t? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != own && !$0.isTerminated }?
            .processIdentifier
    }

    /// Popisovač zamčeného souboru; drží se otevřený po celý běh, zámek uvolní až konec procesu.
    @MainActor private static var instanceLock: Int32 = -1

    /// Běžné spuštění si zabere výhradní zámek souboru; uspěje právě jedna instance, i když jich
    /// startuje víc ve stejný okamžik. Zkušební spuštění zámek nebere, takže běžnému nepřekáží.
    /// `false` = zámek drží jiná běžící instance. Když soubor zámku nejde otevřít, rozhodne se
    /// náhradně podle běžících procesů.
    @MainActor
    static func claimSingleInstance() -> Bool {
        guard instanceLock < 0 else { return true }
        let fileManager = FileManager.default
        guard let bundleID = Bundle.main.bundleIdentifier,
              let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true) else {
            return otherRunningInstance() == nil
        }
        let folder = support.appendingPathComponent(bundleID, isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent("instance.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return otherRunningInstance() == nil }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            instanceLock = descriptor
            return true
        }
        let heldByOther = errno == EWOULDBLOCK
        close(descriptor)
        return heldByOther ? false : otherRunningInstance() == nil
    }

    /// Nastavení pro toto spuštění. Zkušební dostane vlastní sadu, která se při každém spuštění
    /// vyprázdní, takže se chová jako nastavení jen v paměti: nic nepřečte z minula a skutečné
    /// předvolby aplikace zůstanou nedotčené.
    static func makeDefaults() -> UserDefaults {
        guard isDiagnostic, let isolated = UserDefaults(suiteName: diagnosticSuiteName) else {
            return .standard
        }
        isolated.removePersistentDomain(forName: diagnosticSuiteName)
        return isolated
    }

    /// Při ukončení zkušebního spuštění: po zkoušce nezůstane v předvolbách ani oddělená sada.
    static func discardDiagnosticDefaults() {
        guard isDiagnostic else { return }
        UserDefaults(suiteName: diagnosticSuiteName)?.removePersistentDomain(forName: diagnosticSuiteName)
    }
}
