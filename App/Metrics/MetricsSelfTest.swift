import Foundation

/// Kontrolní výpis pro přepínač `--selftest`: dva vzorky po sekundě, hodnoty jako prostý text.
enum MetricsSelfTest {
    static func run() async {
        let collector = MetricsCollector()
        try? await Task.sleep(for: .seconds(1))
        let first = await collector.sample(detail: .full)
        try? await Task.sleep(for: .seconds(1))
        let second = await collector.sample(detail: .full)
        for (index, snapshot) in [first, second].enumerated() {
            print("== vzorek \(index + 1) ==")
            print(describe(snapshot))
        }
    }

    static func describe(_ snapshot: SystemSnapshot) -> String {
        var lines: [String] = []
        let missing = "nedostupné"

        if let cpu = snapshot.cpu {
            lines.append("CPU celkem: \(MetricsFormatter.percent(cpu.total, fractionDigits: 1))")
            lines.append("CPU jádra (\(cpu.perCore.count)): " + cpu.perCore.map { MetricsFormatter.percent($0) }.joined(separator: " "))
        } else {
            lines.append("CPU: \(missing)")
        }

        if let memory = snapshot.memory {
            lines.append("RAM celkem: \(MetricsFormatter.bytes(memory.total, binary: true)) (\(memory.total) B)")
            lines.append("RAM využito: \(MetricsFormatter.bytes(memory.used, binary: true)) (\(memory.used) B)")
            lines.append("RAM volno: \(MetricsFormatter.bytes(memory.free, binary: true))")
            lines.append("RAM komprimováno: \(MetricsFormatter.bytes(memory.compressed, binary: true)) (\(memory.compressed) B)")
            lines.append("RAM tlak: \(memory.pressure.map { "\($0)" } ?? missing)")
        } else {
            lines.append("RAM: \(missing)")
        }

        if let disk = snapshot.disk {
            lines.append("Disk celkem: \(MetricsFormatter.bytes(disk.total)) (\(disk.total) B)")
            lines.append("Disk volno: \(MetricsFormatter.bytes(disk.free)) (\(disk.free) B)")
            lines.append("Disk využito: \(MetricsFormatter.bytes(disk.used))")
        } else {
            lines.append("Disk: \(missing)")
        }

        if let gpu = snapshot.gpu {
            lines.append("GPU: \(MetricsFormatter.percent(gpu.utilization)) (\(gpu.name ?? "bez názvu"))")
        } else {
            lines.append("GPU: \(missing)")
        }

        if let network = snapshot.network {
            lines.append("Síť stahování: \(MetricsFormatter.rate(network.downloadBytesPerSecond)) (\(Int(network.downloadBytesPerSecond)) B/s)")
            lines.append("Síť odesílání: \(MetricsFormatter.rate(network.uploadBytesPerSecond)) (\(Int(network.uploadBytesPerSecond)) B/s)")
            lines.append("Síť rozhraní: \(network.primaryInterface ?? missing)")
            lines.append("Síť SSID: \(network.ssid ?? missing)")
        } else {
            lines.append("Síť: \(missing)")
        }
        return lines.joined(separator: "\n")
    }
}
