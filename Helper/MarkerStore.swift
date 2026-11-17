import Foundation

/// Obsah značky „režim nikdy neusínat jsme zapnuli my". Rozhodující je existence souboru
/// a `previousSleepDisabled`; ostatní pole slouží jen pro diagnostiku.
struct MarkerRecord: Codable, Sendable {
    var enabledAt: Date
    var batteryThresholdPercent: Int
    var thermalLimit: Int
    var expiresAfter: Double
    /// Hodnota SleepDisabled před zapnutím; na tu se nastavení vrací. `nil` (starší značka) = 0.
    var previousSleepDisabled: Bool?
}

/// Obsah značky „úsporný režim jsme zapnuli my": hodnoty `lowpowermode` před zapnutím,
/// zvlášť pro každý zdroj napájení. Na ty se nastavení vrací.
struct LowPowerMarkerRecord: Codable, Sendable {
    var enabledAt: Date
    var previous: LowPowerState
}

/// Trvalá značka, podle které daemon po pádu nebo restartu pozná, že má nastavení vrátit.
/// Každé držené nastavení má vlastní značku (vlastní soubor).
protocol MarkerStoring<Record>: Sendable {
    associatedtype Record: Codable & Sendable
    func exists() -> Bool
    /// Obsah značky; nil, když neexistuje nebo ji nelze přečíst.
    func read() -> Record?
    func write(_ record: Record) -> Bool
    func remove() -> Bool
}

/// Kde značky leží.
enum MarkerLocation {
    static let directory = "/Library/Application Support/cz.stayup.StayUp"
    static let noSleepFileName = "nosleep.marker"
    static let lowPowerFileName = "lowpower.marker"
}

/// Značka jako soubor v adresáři, do kterého smí jen vlastník (root): adresář 0700, soubor 0600.
struct FileMarkerStore<Record: Codable & Sendable>: MarkerStoring {
    let directory: String
    let fileName: String
    private var path: String { directory + "/" + fileName }

    init(fileName: String, directory: String = MarkerLocation.directory) {
        self.directory = directory
        self.fileName = fileName
    }

    func exists() -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    func read() -> Record? {
        // O_NOFOLLOW: nikdy nečíst skrz symbolický odkaz.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Značka má pár set bajtů; cokoli většího není naše.
        let limit = 16 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        guard data.count <= limit else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    func write(_ record: Record) -> Bool {
        guard prepareDirectory() else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return false }

        // Zápis je atomický: nejdřív do dočasného souboru ve stejném adresáři, potom `rename` přes
        // značku. Když cokoli selže, dosavadní značka zůstává nedotčená a nevznikne žádná prázdná
        // nebo neúplná, kterou by daemon později četl jako „původně vypnuto".
        let tmp = path + ".tmp"
        _ = unlink(tmp)   // zbytek po pádu uprostřed dřívějšího zápisu
        // O_EXCL + O_NOFOLLOW: vždy nový soubor, nikdy nepsat skrz symbolický odkaz.
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            helperLog.error("Značku nelze otevřít: errno \(errno, privacy: .public)")
            return false
        }
        _ = fchmod(fd, 0o600)

        var failure: Int32 = 0
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { errno = EIO; return false }
                offset += n
            }
            return true
        }
        if !written {
            failure = errno
        } else if fsync(fd) != 0 {
            failure = errno
        }
        if close(fd) != 0 && failure == 0 && errno != EINTR { failure = errno }
        if failure == 0 && rename(tmp, path) != 0 { failure = errno }
        guard failure == 0 else {
            _ = unlink(tmp)
            helperLog.error("Značku nelze zapsat: errno \(failure, privacy: .public)")
            return false
        }
        // Trvanlivost přejmenování; značka už platí, proto se výsledek jen zkouší.
        let dirFD = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dirFD >= 0 {
            _ = fsync(dirFD)
            close(dirFD)
        }
        return true
    }

    func remove() -> Bool {
        if unlink(path) == 0 || errno == ENOENT { return true }
        helperLog.error("Značku nelze smazat: errno \(errno, privacy: .public)")
        return false
    }

    /// Vytvoří adresář a ověří, že je to skutečný adresář patřící nám, bez přístupu pro ostatní.
    private func prepareDirectory() -> Bool {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            helperLog.error("Adresář značky nelze vytvořit: errno \(errno, privacy: .public)")
            return false
        }
        var st = stat()
        guard lstat(directory, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == geteuid() else {
            helperLog.error("Adresář značky není důvěryhodný")
            return false
        }
        if (st.st_mode & 0o777) != 0o700 && chmod(directory, 0o700) != 0 {
            helperLog.error("Adresáři značky nelze nastavit práva")
            return false
        }
        return true
    }
}
