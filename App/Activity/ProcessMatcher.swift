import Foundation

/// Rozhoduje, které procesy patří mezi sledované „AI“ procesy. Čistá logika bez systémových volání.
///
/// Pravidlo shody (bez ohledu na velikost písmen):
/// - porovnává se název procesu (`proc_name`) a poslední část cesty ke spustitelnému souboru (`proc_pidpath`);
///   stačí, když vyhoví jedno z nich,
/// - vzor vyhoví, když se názvu **přesně rovná**, nebo když název vzorem **začíná**
///   (`claude` → `Claude`, `Claude Helper (Renderer)`, `claude`; `node` → `node`, `nodemon`),
/// - vzory kratší než `minimumPrefixLength` znaky platí jen jako přesná shoda, aby jedno písmeno
///   nezachytilo půlku systému,
/// - vzory se ořezávají o okolní mezery; prázdné a opakované se zahazují.
struct ProcessMatcher: Sendable, Equatable {
    /// Výchozí vzory. Na velikosti písmen nezáleží, takže `Claude` i `claude` pokrývá jeden zápis.
    /// `python` mezi výchozími záměrně není.
    static let defaultPatterns = ["claude", "node", "ollama", "codex"]

    /// Kratší vzory se berou jen jako přesná shoda.
    static let minimumPrefixLength = 3

    /// Vyčištěné vzory malými písmeny, v původním pořadí.
    let patterns: [String]

    init(patterns: [String] = ProcessMatcher.defaultPatterns) {
        self.patterns = Self.normalize(patterns)
    }

    var isEmpty: Bool { patterns.isEmpty }

    /// Vyhoví-li aspoň jeden z názvů (prázdné a `nil` se přeskakují).
    func matches(_ names: String?...) -> Bool {
        for case let name? in names where matches(name: name) { return true }
        return false
    }

    func matches(name: String) -> Bool {
        guard !name.isEmpty, !patterns.isEmpty else { return false }
        let lowered = name.lowercased()
        for pattern in patterns {
            if lowered == pattern { return true }
            if pattern.count >= Self.minimumPrefixLength, lowered.hasPrefix(pattern) { return true }
        }
        return false
    }

    /// Ořízne, převede na malá písmena, zahodí prázdné a opakované. Vhodné i pro uložení seznamu z nastavení.
    static func normalize(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty, seen.insert(pattern).inserted else { continue }
            result.append(pattern)
        }
        return result
    }
}
