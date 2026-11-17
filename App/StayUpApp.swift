import AppKit
import SwiftUI

/// Vstupní bod. Testovací přepínače se vyřídí dřív, než vznikne rozhraní.
@main
enum StayUpMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest") {
            Task.detached {
                await MetricsSelfTest.run()
                exit(0)
            }
            dispatchMain()
        }
        if arguments.contains("--selftest-assertion") {
            runAssertionSelfTest()
        }
        StayUpApp.main()
    }

    /// Ověření přepínače A: drží assertion 20 s (kontrola přes `pmset -g assertions`).
    private static func runAssertionSelfTest() -> Never {
        let assertion = AwakeAssertion()
        guard assertion.acquire() else {
            print("ASSERTION_FAILED")
            exit(1)
        }
        print("ASSERTION_HELD")
        fflush(stdout)
        sleep(20)
        assertion.release()
        print("ASSERTION_RELEASED")
        exit(0)
    }
}

struct StayUpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: AppModel.shared)
        } label: {
            MenuBarLabel(metrics: AppModel.shared.metrics, sleep: AppModel.shared.sleep)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        installSignalHandlers()
        if CommandLine.arguments.contains("--preview-window") {
            showPreviewWindow()
        }
        if CommandLine.arguments.contains("--auto-open") {
            // Jen pro měření: po startu otevře skutečný panel pod ikonou v liště.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                for window in NSApp.windows where window.className.contains("StatusBar") {
                    if let button = Self.firstButton(in: window.contentView) {
                        button.performClick(nil)
                        print("AUTO_OPEN clicked")
                        fflush(stdout)
                    }
                }
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            snapshotPanel(to: CommandLine.arguments[index + 1])
        }
    }

    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for sub in view.subviews {
            if let found = firstButton(in: sub) { return found }
        }
        return nil
    }

    /// Jen s argumentem `--snapshot <soubor.png>`: vykreslí panel mimo obrazovku do obrázku a skončí.
    /// Slouží ke kontrole rozvržení; nepotřebuje oprávnění ke snímání obrazovky. S `--snapshot-on`
    /// se před snímkem zapne první přepínač (jen blokace spánku, při ukončení se uvolní).
    private func snapshotPanel(to path: String) {
        if CommandLine.arguments.contains("--snapshot-on") {
            AppModel.shared.sleep.setKeepAwake(true)
        }
        let host = NSHostingView(rootView: PanelView(model: AppModel.shared))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 340, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.13, alpha: 1)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        previewWindow = window
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            var size = host.fittingSize
            let fitting = size
            // Skutečné okno v liště nemůže být vyšší než obrazovka; snímek to napodobí.
            if let limit = CommandLine.arguments.firstIndex(of: "--snapshot-height"),
               CommandLine.arguments.indices.contains(limit + 1),
               let height = Double(CommandLine.arguments[limit + 1]) {
                size.height = min(size.height, height)
            }
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .seconds(1))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                if let context = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    NSColor(white: 0.13, alpha: 1).setFill()
                    host.bounds.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            print("SNAPSHOT \(Int(size.width))x\(Int(size.height)) fitting \(Int(fitting.width))x\(Int(fitting.height)) visible \(Int(NSScreen.main?.visibleFrame.height ?? 0))")
            NSApp.terminate(nil)
        }
    }

    /// Jen s argumentem `--preview-window`: stejný panel v běžném okně, aby šlo rozvržení
    /// vyfotit bez klepání na ikonu v řádku nabídek. Na normální spuštění nemá vliv.
    private func showPreviewWindow() {
        NSApp.setActivationPolicy(.regular)
        let controller = NSHostingController(rootView: PanelView(model: AppModel.shared))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Stay Up – náhled panelu"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        previewWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    /// SIGTERM a SIGINT ukončí aplikaci řádně, aby se spánek Macu stihl vrátit.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
