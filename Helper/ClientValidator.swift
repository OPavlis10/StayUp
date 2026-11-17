import Foundation
import Security

/// Ověření, že se k daemonovi připojuje právě aplikace Stay Up, ve které je tento daemon zabalený.
///
/// Aplikace je podepsaná ad hoc („Sign to Run Locally"), takže neexistuje Team ID, o které by se
/// dalo opřít. Identifikátor `cz.stayup.StayUp` si může do ad hoc podpisu napsat kdokoli, proto se
/// navíc vyžaduje:
///  1. podpis balíčku aplikace na disku je platný a nese správný identifikátor,
///  2. běžící klient má stejný cdhash jako hlavní spustitelný soubor tohoto balíčku
///     (ověřuje jádro přes audit token, ne PID – nehrozí záměna při recyklaci PID),
///  3. hlavní spustitelný soubor klienta leží ve stejném `.app`, ze kterého běží tento daemon.
///
/// Zbytkové riziko: kdo smí zapisovat do balíčku aplikace (např. leží-li v adresáři zapisovatelném
/// uživatelem), může ho celý nahradit vlastním – včetně tohoto daemona, kterého launchd spouští
/// podle cesty. To bez Developer ID nejde vyloučit. Stejně tak lze do ad hoc podepsané aplikace
/// bez hardened runtime vnutit cizí knihovnu (DYLD_INSERT_LIBRARIES) a mluvit s daemonem jejím
/// jménem. Dopad je záměrně omezený: daemon umí jen zapnout a vypnout `disablesleep` a nikdy
/// nespouští nic odvozeného ze vstupu klienta.
enum ClientValidator {

    /// Kořen `.app`, ve kterém daemon leží (`…/Stay Up.app`), nebo nil, když neběží z balíčku.
    static let appBundleURL: URL? = {
        guard let path = ownExecutablePath() else { return nil }
        // Hledá se nejbližší předek „X.app", pod kterým cesta pokračuje přes „Contents"
        // (pokrývá Contents/MacOS/StayUpHelper i Contents/Library/…/StayUpHelper).
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 3 else { return nil }
        for index in stride(from: components.count - 3, through: 1, by: -1)
        where components[index].hasSuffix(".app") && components[index + 1] == "Contents" {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(components[0...index])),
                       isDirectory: true)
        }
        return nil
    }()

    /// Při úspěchu vrací řetězec požadavku na podpis, který má volající ještě nastavit na spojení
    /// (`setCodeSigningRequirement`), aby systém kontroloval každou zprávu. Při neúspěchu nil.
    static func validate(_ connection: NSXPCConnection) -> String? {
        guard let bundleURL = appBundleURL else {
            helperLog.error("Daemon neběží z balíčku aplikace, spojení odmítnuto")
            return nil
        }
        guard let token = auditToken(of: connection) else {
            helperLog.error("Nelze získat audit token klienta")
            return nil
        }

        // 1. Balíček na disku: platný podpis se správným identifikátorem.
        let identifierText = "identifier \"\(HelperConstants.appBundleID)\""
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              let identifierRequirement = requirement(identifierText) else {
            helperLog.error("Nelze načíst podpis balíčku aplikace")
            return nil
        }
        let staticFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        let staticStatus = SecStaticCodeCheckValidity(staticCode, staticFlags, identifierRequirement)
        guard staticStatus == errSecSuccess else {
            helperLog.error("Podpis balíčku aplikace není platný (\(staticStatus, privacy: .public))")
            return nil
        }
        guard let bundleInfo = signingInfo(staticCode),
              let cdhash = bundleInfo[kSecCodeInfoUnique as String] as? Data, !cdhash.isEmpty,
              let bundleExecutable = (bundleInfo[kSecCodeInfoMainExecutable as String] as? URL)
                .flatMap({ resolved($0.path) }) else {
            helperLog.error("Nelze zjistit cdhash balíčku aplikace")
            return nil
        }

        // 2. Běžící klient: stejný identifikátor a stejný cdhash jako balíček na disku.
        let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
        var clientCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &clientCode) == errSecSuccess,
              let clientCode else {
            helperLog.error("Nelze získat podpis běžícího klienta")
            return nil
        }
        let hex = cdhash.map { String(format: "%02x", $0) }.joined()
        let fullText = "\(identifierText) and cdhash H\"\(hex)\""
        guard let fullRequirement = requirement(fullText) else { return nil }
        let clientStatus = SecCodeCheckValidity(clientCode, [], fullRequirement)
        guard clientStatus == errSecSuccess else {
            helperLog.error("Klient nesplňuje požadavek na podpis (\(clientStatus, privacy: .public))")
            return nil
        }

        // 3. Klient běží ze stejného balíčku jako daemon.
        var clientStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(clientCode, [], &clientStatic) == errSecSuccess,
              let clientStatic,
              let clientInfo = signingInfo(clientStatic),
              let clientExecutable = (clientInfo[kSecCodeInfoMainExecutable as String] as? URL)
                .flatMap({ resolved($0.path) }),
              let bundleRoot = resolved(bundleURL.path) else {
            helperLog.error("Nelze zjistit cestu klienta")
            return nil
        }
        guard clientExecutable == bundleExecutable,
              clientExecutable.hasPrefix(bundleRoot + "/Contents/MacOS/") else {
            helperLog.error("Klient neběží z balíčku tohoto daemona: \(clientExecutable, privacy: .public)")
            return nil
        }
        return fullText
    }

    // MARK: - Pomocné

    /// Audit token protistrany. Veřejné API ho v SDK 26.5 na NSXPCConnection nenabízí, proto se čte
    /// dlouhodobě stabilní soukromá vlastnost `auditToken` přes KVC. Když by zmizela, spojení se
    /// odmítne (bezpečný směr), nic nespadne.
    private static func auditToken(of connection: NSXPCConnection) -> Data? {
        guard connection.responds(to: NSSelectorFromString("auditToken")),
              let value = connection.value(forKey: "auditToken") as? NSValue else {
            return nil
        }
        var size = 0
        NSGetSizeAndAlignment(value.objCType, &size, nil)
        guard size == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: size)
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var result: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &result) == errSecSuccess else {
            helperLog.error("Nelze sestavit požadavek na podpis")
            return nil
        }
        return result
    }

    private static func signingInfo(_ code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }

    private static func ownExecutablePath() -> String? {
        if let path = Bundle.main.executablePath, let real = resolved(path) {
            return real
        }
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return resolved(String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// realpath: bez symbolických odkazů a „..".
    private static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
