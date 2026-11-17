import Foundation

/// Okamžitě uspí displej (`pmset displaysleepnow`, nevyžaduje oprávnění).
enum DisplaySleeper {
    /// Spustí příkaz mimo hlavní vlákno. Vrací `true`, když skončil úspěšně.
    @concurrent
    @discardableResult
    static func sleepNow() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Handler se zavolá právě jednou, a to jen když se proces podařilo spustit.
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}
