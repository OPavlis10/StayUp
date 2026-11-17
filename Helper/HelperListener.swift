import Foundation

/// Objekt vystavený jednomu XPC spojení. Jen předává volání stavovému automatu.
final class HelperService: NSObject, HelperXPCProtocol, Sendable {
    private let clientID: HelperController.ClientID
    private let controller: HelperController

    init(clientID: HelperController.ClientID, controller: HelperController) {
        self.clientID = clientID
        self.controller = controller
    }

    func getStatus(reply: @escaping @Sendable (Int, Bool, Bool) -> Void) {
        controller.status { status in
            reply(HelperConstants.protocolVersion, status.sleepDisabled, status.heldByHelper)
        }
    }

    func enableNoSleep(batteryThresholdPercent: Int,
                       thermalLimit: Int,
                       expiresAfter: Double,
                       reply: @escaping @Sendable (Bool, String?) -> Void) {
        controller.enableNoSleep(client: clientID,
                                 batteryThresholdPercent: batteryThresholdPercent,
                                 thermalLimit: thermalLimit,
                                 expiresAfter: expiresAfter,
                                 completion: reply)
    }

    func disableNoSleep(reply: @escaping @Sendable (Bool, String?) -> Void) {
        controller.disableNoSleep(client: clientID, completion: reply)
    }

    func getLowPowerStatus(reply: @escaping @Sendable (Bool, Bool, Bool) -> Void) {
        controller.lowPowerStatus { status in
            reply(status.supported, status.enabled, status.heldByHelper)
        }
    }

    func enableLowPower(reply: @escaping @Sendable (Bool, String?) -> Void) {
        controller.enableLowPower(client: clientID, completion: reply)
    }

    func disableLowPower(reply: @escaping @Sendable (Bool, String?) -> Void) {
        controller.disableLowPower(client: clientID, completion: reply)
    }

    func heartbeat(reply: @escaping @Sendable (Bool, Int, Bool, Int) -> Void) {
        controller.heartbeat(client: clientID) { beat in
            reply(beat.noSleepActive, beat.noSleepStopReason.rawValue,
                  beat.lowPowerActive, beat.lowPowerStopReason.rawValue)
        }
    }
}

/// Přijímá spojení na Mach službě a pouští dál jen ověřenou aplikaci.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let controller: HelperController

    init(controller: HelperController) {
        self.controller = controller
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = ClientValidator.validate(connection) else {
            helperLog.error("Spojení od PID \(connection.processIdentifier, privacy: .public) odmítnuto")
            return false
        }
        // Systém navíc ověří proti stejnému požadavku každou příchozí zprávu.
        connection.setCodeSigningRequirement(requirement)

        let clientID = HelperController.ClientID()
        let controller = self.controller
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = HelperService(clientID: clientID, controller: controller)
        // Handlery nedrží spojení samotné, takže nevzniká cyklus.
        connection.invalidationHandler = { controller.connectionClosed(clientID) }
        connection.interruptionHandler = { controller.connectionClosed(clientID) }

        controller.connectionOpened(clientID)
        connection.resume()
        helperLog.info("Spojení od PID \(connection.processIdentifier, privacy: .public) přijato")
        return true
    }
}
