import Foundation

/// Vlastní vzorkovače modulu Energie i jejich předchozí stav. Jako actor běží mimo hlavní vlákno.
/// Volat jen při otevřeném panelu; při zavření zavolat `panelClosed()`.
actor EnergyCollector {
    private var processes = TopProcessSampler(idleStride: 4)
    private var power = PowerDrawSampler()

    /// Nabere výchozí stav počítadel procesů, aby první `sampleProcesses()` po otevření panelu
    /// (o ~5 s později) už vrátil žebříček. Volat při otevření panelu.
    func panelOpened() {
        processes.reset()
        _ = processes.sample()
    }

    /// Uvolní stav procesů; baterie si vyhlazený odběr nechá (po delší pauze se zahodí sám).
    func panelClosed() {
        processes.reset()
    }

    /// Žebříček za dobu od předchozího volání; zhruba každých 5 s. `nil`, když ještě není s čím porovnat.
    func sampleProcesses(limit: Int = 5) -> TopProcessesSnapshot? {
        processes.sample(limit: limit)
    }

    /// Příkon a baterie; zhruba každých 10 s. `nil` na Macu bez baterie.
    func samplePower() -> PowerDrawMetrics? {
        power.sample()
    }
}
