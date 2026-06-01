import CoreData
import Foundation
import OSLog
import SwiftUI

/// One curated interaction between two drugs. Decoded from the bundled JSON;
/// `id` is synthesized (not in the file) so the corpus stays clean.
struct DrugInteraction: Codable, Identifiable, Equatable {
    let drugA: String
    let drugB: String
    let severity: Severity
    let description: String
    let recommendation: String

    /// Stable, order-independent id: the two names lowercased and sorted,
    /// joined by "|". Lets `allInteractionsFor` dedupe regardless of iteration
    /// order. Computed, so it isn't expected in the JSON.
    var id: String { [drugA.lowercased(), drugB.lowercased()].sorted().joined(separator: "|") }

    enum Severity: String, Codable, CaseIterable, Equatable {
        case informational, moderate, severe

        /// Design-system color for the severity pill / banner tint.
        var displayColor: Color {
            switch self {
            case .informational: return .dsSuccess
            case .moderate:      return .dsWarning
            case .severe:        return .dsDanger
            }
        }

        var localizedNameKey: String { "interactions.severity.\(rawValue)" }
        var localizedName: String { L(localizedNameKey) }

        /// Worst-first ordering for the banner's "worst severity wins" cascade.
        var rank: Int {
            switch self {
            case .informational: return 0
            case .moderate:      return 1
            case .severe:        return 2
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case drugA, drugB, severity, description, recommendation
    }
}

/// Looks up curated drug interactions from the bundled corpus. Pure, local,
/// synchronous — a lookup against ~30 entries is microseconds, and there is no
/// remote interaction state to sync. Language-aware the same way
/// `DrugInfoRepository` is: `pa` reads `drug_interactions_pa.json`, falling
/// through to English per-entry for any id the Punjabi file is missing.
final class DrugInteractionService {
    static let shared = DrugInteractionService()

    private let bundle: Bundle
    private let explicitLanguage: String?
    private static let logger = Logger(subsystem: "com.medication.dosely", category: "interactions")

    init(bundle: Bundle = .main, language: String? = nil) {
        self.bundle = bundle
        self.explicitLanguage = language
    }

    private var language: String {
        explicitLanguage ?? UserDefaults.standard.string(forKey: "app_language") ?? "en"
    }

    // Lazy: load once on first access, keep in memory.
    private lazy var english: [DrugInteraction] = Self.load(bundle: bundle, filename: "drug_interactions")
    private lazy var punjabi: [DrugInteraction] = Self.load(bundle: bundle, filename: "drug_interactions_pa")

    /// Active-language corpus. `pa` merges the Punjabi strings over English by
    /// id; any id missing from the Punjabi file keeps the English entry.
    private var corpus: [DrugInteraction] {
        guard language == "pa", !punjabi.isEmpty else { return english }
        let paByID = Dictionary(punjabi.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return english.map { paByID[$0.id] ?? $0 }
    }

    private struct Payload: Codable { let interactions: [DrugInteraction] }

    private static func load(bundle: Bundle, filename: String) -> [DrugInteraction] {
        guard let url = bundle.url(forResource: filename, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            // A corrupt bundled resource is a build error, not a runtime concern,
            // but log it so a future "why are interactions empty" has a trail.
            logger.error("Failed to load \(filename, privacy: .public).json — interactions disabled")
            return []
        }
        return payload.interactions
    }

    // MARK: - Lookup

    /// Interactions affecting `medication`, where the OTHER participant is also
    /// in `patientMedications` (an interaction only fires when both drugs are
    /// actually present in the patient's regimen).
    func interactionsFor(medication: Medication, in patientMedications: [Medication]) -> [DrugInteraction] {
        interactionsFor(medicationNamed: medication.name ?? "", in: patientMedications)
    }

    /// Name-based variant for callers (e.g. `MedicationDetailView`) that hold a
    /// medication name rather than the managed object.
    func interactionsFor(medicationNamed name: String, in patientMedications: [Medication]) -> [DrugInteraction] {
        let current = Self.normalize(name)
        guard !current.isEmpty else { return [] }
        let present = presentNames(patientMedications)
        return corpus.filter { interaction in
            let a = Self.normalize(interaction.drugA)
            let b = Self.normalize(interaction.drugB)
            return (a == current && present.contains(b)) || (b == current && present.contains(a))
        }
    }

    /// Every distinct interaction across the patient's full medication list,
    /// deduplicated by id.
    func allInteractionsFor(patient medications: [Medication]) -> [DrugInteraction] {
        let present = presentNames(medications)
        var seen = Set<String>()
        var result: [DrugInteraction] = []
        for interaction in corpus {
            let a = Self.normalize(interaction.drugA)
            let b = Self.normalize(interaction.drugB)
            guard present.contains(a), present.contains(b) else { continue }
            if seen.insert(interaction.id).inserted { result.append(interaction) }
        }
        return result
    }

    /// English version of an interaction by id — for the voice fallback when
    /// the language is `pa` but no `pa-IN` voice is installed.
    func englishInteraction(id: String) -> DrugInteraction? {
        english.first { $0.id == id }
    }

    private func presentNames(_ medications: [Medication]) -> Set<String> {
        Set(medications.compactMap { $0.name.map(Self.normalize) }.filter { !$0.isEmpty })
    }

    private static func normalize(_ string: String) -> String {
        string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
