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

enum DrugSource {
    case curated(DrugInfo)
    case dynamic(OpenFDADrug, sourceLabel: String)
    case missing
}

final class DrugInfoRepository {
    static let shared = DrugInfoRepository()

    private let drugs: [DrugInfo]
    private let cache: DrugInfoCache
    private let remote: DrugRemoteService

    /// Best-effort flag flipped after every Tier 3 attempt. UI may use it to
    /// decide between "offline" copy and a generic retry message. Not a
    /// reachability guarantee.
    private(set) var hasNetworkRecently: Bool = true

    init(bundle: Bundle = .main,
         filename: String = "drug_info",
         cache: DrugInfoCache = .shared,
         remote: DrugRemoteService = OpenFDADrugService()) {
        self.drugs = Self.load(bundle: bundle, filename: filename)
        self.cache = cache
        self.remote = remote
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

    /// Total curated entries — useful for tests and logging.
    var count: Int { drugs.count }

    // MARK: - Tier 1 — curated lookup (fast, offline, plain-language)

    /// Looks up a curated entry by an arbitrary medication name. Matching is
    /// case-insensitive, whitespace-trimmed, with a longest-substring fuzzy
    /// fallback so input like "Atorvastatin 20mg" still resolves.
    func lookupCurated(for medName: String) -> DrugInfo? {
        let normalized = medName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        for drug in drugs {
            if drug.nameKey.lowercased() == normalized { return drug }
            for common in drug.commonNames where common.lowercased() == normalized {
                return drug
            }
        }

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

    // MARK: - Three-tier orchestration

    /// Looks up info across all three tiers. Always returns a `DrugSource`;
    /// throws only when Tier 3 fails *and* there is no Tier 1 / Tier 2 fallback,
    /// so callers can show a retry banner without losing the offline-first
    /// guarantee for known meds.
    func lookupAny(for medName: String) async throws -> DrugSource {
        // Tier 1 — curated catalogue
        if let curated = lookupCurated(for: medName) {
            return .curated(curated)
        }

        // Tier 2 — on-disk cache of prior openFDA fetches
        if let cached = await cache.get(medName) {
            return .dynamic(cached, sourceLabel: "openFDA · DailyMed (cached)")
        }

        // Tier 3 — live openFDA query
        do {
            let result = try await remote.fetchInfo(for: medName)
            hasNetworkRecently = true
            if let drug = result {
                await cache.set(medName, drug)
                return .dynamic(drug, sourceLabel: "openFDA · DailyMed")
            }
            return .missing
        } catch {
            hasNetworkRecently = false
            throw error
        }
    }
}
