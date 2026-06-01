import XCTest
@testable import Dosely

/// Validates the curated interaction corpus at test time so curation errors —
/// typos, duplicate pairs, severity drift, a missing Punjabi translation —
/// fail here rather than silently in production (a typo'd drug name would just
/// never match the patient's medication).
final class DrugInteractionsCorpusValidationTests: XCTestCase {
    private struct RawInteraction: Codable {
        let drugA: String
        let drugB: String
        let severity: String
        let description: String
        let recommendation: String
    }
    private struct Payload: Codable { let interactions: [RawInteraction] }

    private func load(_ filename: String) throws -> [RawInteraction] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: filename, withExtension: "json"),
                                "\(filename).json missing from the bundle")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Payload.self, from: data).interactions
    }

    private func pairID(_ e: RawInteraction) -> String {
        [e.drugA.lowercased(), e.drugB.lowercased()].sorted().joined(separator: "|")
    }

    func test_englishCorpusParsesWithAtLeast20Entries() throws {
        XCTAssertGreaterThanOrEqual(try load("drug_interactions").count, 20)
    }

    func test_everySeverityIsOneOfThreeValidValues() throws {
        let valid: Set<String> = ["informational", "moderate", "severe"]
        for e in try load("drug_interactions") {
            XCTAssertTrue(valid.contains(e.severity),
                          "invalid severity '\(e.severity)' on \(e.drugA) + \(e.drugB)")
        }
    }

    func test_noEmptyDrugNamesOrText() throws {
        for e in try load("drug_interactions") {
            XCTAssertFalse(e.drugA.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(e.drugB.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(e.description.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(e.recommendation.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func test_noDuplicatePairs() throws {
        var seen = Set<String>()
        for e in try load("drug_interactions") {
            XCTAssertTrue(seen.insert(pairID(e)).inserted, "duplicate pair: \(pairID(e))")
        }
    }

    func test_englishAndPunjabiHaveTheSameEntryCount() throws {
        XCTAssertEqual(try load("drug_interactions").count, try load("drug_interactions_pa").count,
                       "every English interaction needs a Punjabi entry — counts must match")
    }

    func test_englishAndPunjabiCoverTheSamePairs() throws {
        let en = Set(try load("drug_interactions").map(pairID))
        let pa = Set(try load("drug_interactions_pa").map(pairID))
        XCTAssertEqual(en, pa, "a Punjabi entry must not drift to a different drug pair")
    }

    func test_everyDrugNameIsKnown() throws {
        // A drug name must be either a name from drug_info.json OR in the
        // explicit allowlist of additional real, FDA-labelling-sourceable
        // interacting drugs that aren't in the 8-entry info corpus (NSAIDs,
        // common geriatric polypharmacy). Catches typos that would silently
        // never match a patient's medication. The allowlist is the only
        // reference for the non-info drugs, so it is kept short and reviewed
        // deliberately.
        let allowlist: Set<String> = [
            "ibuprofen", "naproxen", "amiodarone", "sertraline", "tramadol",
            "spironolactone", "potassium chloride", "lithium", "clarithromycin",
            "diltiazem", "simvastatin", "metoprolol", "digoxin", "furosemide",
            "hydrochlorothiazide", "clopidogrel", "calcium carbonate"
        ]
        let known = try Self.drugInfoNames().union(allowlist)
        for e in try load("drug_interactions") {
            XCTAssertTrue(known.contains(e.drugA.lowercased()),
                          "unknown drug name '\(e.drugA)' — typo, or missing from drug_info.json / allowlist")
            XCTAssertTrue(known.contains(e.drugB.lowercased()),
                          "unknown drug name '\(e.drugB)' — typo, or missing from drug_info.json / allowlist")
        }
    }

    /// All nameKeys + commonNames from drug_info.json, lowercased.
    private static func drugInfoNames() throws -> Set<String> {
        struct Med: Codable { let nameKey: String; let commonNames: [String] }
        struct P: Codable { let meds: [Med] }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "drug_info", withExtension: "json"))
        let meds = try JSONDecoder().decode(P.self, from: Data(contentsOf: url)).meds
        var names = Set<String>()
        for m in meds {
            names.insert(m.nameKey.lowercased())
            m.commonNames.forEach { names.insert($0.lowercased()) }
        }
        return names
    }
}
