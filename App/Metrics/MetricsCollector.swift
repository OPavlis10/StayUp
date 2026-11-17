import Foundation

/// Kolik toho má jeden vzorek spočítat.
enum SampleDetail: Sendable {
    /// CPU (jedno levné systémové volání) + levné obnovení výchozího stavu síťových čítačů –
    /// pro ikonu v liště, když je okno zavřené. Ostatní položky snímku jsou `nil`.
    case menuBarOnly
    /// Všechno: CPU, paměť, disk, GPU, síť.
    case full
}

/// Vlastní všechny vzorkovače i jejich předchozí stav. Jako actor běží mimo hlavní vlákno.
actor MetricsCollector {
    private var cpu: CPUSampler
    private var memory = MemorySampler()
    private var disk = DiskSampler()
    private var gpu = GPUSampler()
    private var network: NetworkSampler
    private var lastDetail: SampleDetail?

    init() {
        // Výchozí stav čítačů (dvě levná volání), aby už první vzorek vrátil CPU i rychlost sítě.
        var cpu = CPUSampler()
        _ = cpu.sample()
        self.cpu = cpu
        var network = NetworkSampler()
        network.prime()
        self.network = network
    }

    /// Rychlosti (CPU, síť) jsou průměr za dobu od předchozího volání; volat nejvýš zhruba jednou za sekundu.
    func sample(detail: SampleDetail = .full) -> SystemSnapshot {
        var snapshot = SystemSnapshot(timestamp: Date(), cpu: cpu.sample())
        defer { lastDetail = detail }
        guard detail == .full else {
            // Síť se nezobrazuje, ale výchozí stav čítačů musí zůstat čerstvý,
            // jinak by první vzorek po otevření panelu byl průměr za celou dobu zavření.
            network.prime()
            return snapshot
        }
        // Po otevření panelu načíst název sítě znovu (mohla se mezitím změnit).
        let reopened = lastDetail == .menuBarOnly
        if reopened { network.invalidateInfo() }
        snapshot.memory = memory.sample()
        // Po otevření panelu nesmí být údaj o disku starší než půl minuty.
        snapshot.disk = disk.sample(maxAge: reopened ? 30 : nil)
        snapshot.gpu = gpu.sample()
        snapshot.network = network.sample()
        return snapshot
    }
}
