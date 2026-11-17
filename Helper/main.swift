// StayUpHelper – privilegovaný daemon aplikace Stay Up. Spouští ho launchd jako root.
// Dvě schopnosti: zapnout a vypnout `pmset disablesleep` a `pmset lowpowermode`.
import Foundation
import notify

let controller = HelperController(
    power: PmsetPowerSetting(),
    environment: SystemEnvironment(),
    noSleepMarker: FileMarkerStore<MarkerRecord>(fileName: MarkerLocation.noSleepFileName),
    lowPowerMarker: FileMarkerStore<LowPowerMarkerRecord>(fileName: MarkerLocation.lowPowerFileName),
    onIdle: { exit(EXIT_SUCCESS) }
)

// Ukončení (SIGTERM od launchd při vypínání či odregistraci, SIGINT): nejdřív vrátit nastavení.
let signalQueue = DispatchQueue(label: "cz.stayup.StayUp.helper.signals")
let signalSources: [any DispatchSourceSignal] = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        helperLog.notice("Přijat signál \(number, privacy: .public), končím")
        // Nepovedlo-li se nastavení vrátit, skončit s chybou: launchd daemon spustí znovu
        // (KeepAlive › SuccessfulExit = false) a vrácení dokončí `controller.start()`.
        controller.shutdown { reverted in exit(reverted ? EXIT_SUCCESS : EXIT_FAILURE) }
    }
    source.resume()
    return source
}

// Změna tepelného stavu a zdroje napájení → okamžitá kontrola (vedle pravidelné po 30 s).
_ = ProcessInfo.processInfo.thermalState
let thermalObserver = NotificationCenter.default.addObserver(
    forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
) { _ in
    controller.environmentChanged()
}
var powerSourceToken: Int32 = 0
notify_register_dispatch("com.apple.system.powersources.source", &powerSourceToken, signalQueue) { _ in
    controller.environmentChanged()
}

// Úklid po nečistém konci předchozího běhu musí proběhnout dřív než první požadavek klienta.
controller.start()

let listenerDelegate = HelperListenerDelegate(controller: controller)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

helperLog.info("StayUpHelper běží")
dispatchMain()
