import Foundation

struct DrugInfo: Codable, Identifiable, Equatable {
    let nameKey: String
    let commonNames: [String]
    let whatItDoes: String
    let howToTake: String
    let commonSideEffects: [String]
    let seriousSideEffects: [String]
    let foodGuide: FoodGuide
    let source: String
    let sourceUrl: String

    var id: String { nameKey }
}

struct FoodGuide: Codable, Equatable {
    let safe: [String]
    let caution: [String]
    let avoid: [String]
}

final class DrugInfoRepository {
    static let shared = DrugInfoRepository()

    private let drugs: [DrugInfo]

    init(bundle: Bundle = .main, filename: String = "drug_info") {
        self.drugs = Self.load(bundle: bundle, filename: filename)
    }

    private struct Payload: Codable {
        let meds: [DrugInfo]
    }

    private static func load(bundle: Bundle, filename: String) -> [DrugInfo] {
        guard
            let url = bundle.url(forResource: filename, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }
        return payload.meds
    }

    /// Looks up drug info by an arbitrary medication name string. Matching is
    /// case-insensitive, whitespace-trimmed, and falls back to a substring
    /// match against `commonNames` so input like "Atorvastatin 20mg" or
    /// "metformin er" still finds the right entry.
    func lookupInfo(for medName: String) -> DrugInfo? {
        let normalized = medName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        // Exact match first
        for drug in drugs {
            if drug.nameKey.lowercased() == normalized { return drug }
            for common in drug.commonNames where common.lowercased() == normalized {
                return drug
            }
        }

        // Fuzzy: bidirectional substring match. Prefers the longest matching
        // common-name so "Aspirin (low-dose)" beats "Aspirin" when both fit.
        var bestMatch: (drug: DrugInfo, length: Int)?
        for drug in drugs {
            let candidates = drug.commonNames + [drug.nameKey]
            for candidate in candidates {
                let lc = candidate.lowercased()
                guard !lc.isEmpty else { continue }
                if normalized.contains(lc) || lc.contains(normalized) {
                    if bestMatch == nil || lc.count > bestMatch!.length {
                        bestMatch = (drug, lc.count)
                    }
                }
            }
        }
        return bestMatch?.drug
    }

    /// Total entries loaded — useful for tests and logging.
    var count: Int { drugs.count }
}
