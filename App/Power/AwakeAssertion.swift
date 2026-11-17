import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Drží IOPMAssertion „PreventUserIdleSystemSleep": Mac neusne nečinností, displej zhasnout smí.
/// Opakované `acquire()` / `release()` jsou bez účinku; při zániku objektu se assertion uvolní.
final class AwakeAssertion: Sendable {
    private let assertionID = Mutex<IOPMAssertionID>(IOPMAssertionID(kIOPMNullAssertionID))

    init() {}

    deinit { release() }

    var isHeld: Bool {
        assertionID.withLock { $0 != IOPMAssertionID(kIOPMNullAssertionID) }
    }

    /// Vytvoří assertion, pokud ještě není. Vrací `false`, když ji systém odmítl.
    @discardableResult
    func acquire() -> Bool {
        assertionID.withLock { id in
            guard id == IOPMAssertionID(kIOPMNullAssertionID) else { return true }
            var newID = IOPMAssertionID(kIOPMNullAssertionID)
            let result = IOPMAssertionCreateWithDescription(
                "PreventUserIdleSystemSleep" as CFString,   // kIOPMAssertPreventUserIdleSystemSleep
                "Stay Up" as CFString,
                String(localized: "Aplikace Stay Up brání uspání Macu.") as CFString,
                String(localized: "Stay Up drží Mac vzhůru, dokud je zapnutý přepínač.") as CFString,
                nil,
                0,
                nil,
                &newID
            )
            guard result == kIOReturnSuccess else { return false }
            id = newID
            return true
        }
    }

    /// Uvolní assertion, pokud je držena.
    func release() {
        assertionID.withLock { id in
            guard id != IOPMAssertionID(kIOPMNullAssertionID) else { return }
            IOPMAssertionRelease(id)
            id = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }
}
