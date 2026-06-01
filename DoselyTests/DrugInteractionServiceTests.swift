import CoreData
import XCTest
@testable import Dosely

/// Behaviour of `DrugInteractionService` against the real bundled corpus.
/// Builds `Medication`s in an in-memory context and checks which interactions
/// fire for a given regimen.
final class DrugInteractionServiceTests: XCTestCase {
    private var stack: CoreDataStack!
    private var service: DrugInteractionService!

    override func setUp() {
        super.setUp()
        stack = CoreDataStack(inMemory: true)
        service = DrugInteractionService(bundle: .main, language: "en")
    }
    override func tearDown() { stack = nil; service = nil; super.tearDown() }

    private func med(_ name: String) -> Medication {
        let m = Medication(context: stack.viewContext)
        m.id = UUID(); m.personID = UUID(); m.name = name
        m.currentSupply = 30; m.dateAdded = Date()
        return m
    }

    private func pairID(_ a: String, _ b: String) -> String {
        [a.lowercased(), b.lowercased()].sorted().joined(separator: "|")
    }

    func test_interactionsFor_returnsPairsWhereBothPresent() {
        let warfarin = med("Warfarin")
        let hits = service.interactionsFor(medication: warfarin,
                                           in: [warfarin, med("Aspirin"), med("Metformin")])
        XCTAssertTrue(hits.contains { $0.id == pairID("warfarin", "aspirin") },
                      "warfarin + aspirin should fire when both are present")
    }

    func test_matching_isCaseInsensitive() {
        let m = med("WARFARIN")
        XCTAssertFalse(service.interactionsFor(medication: m, in: [m, med("aspirin")]).isEmpty)
    }

    func test_matching_trimsWhitespace() {
        let m = med("  Warfarin  ")
        XCTAssertFalse(service.interactionsFor(medication: m, in: [m, med("Aspirin ")]).isEmpty)
    }

    func test_medicationWithNoCuratedPair_returnsEmpty() {
        // metformin has no curated interaction in the corpus.
        let m = med("Metformin")
        XCTAssertTrue(service.interactionsFor(medication: m, in: [m, med("Levothyroxine")]).isEmpty)
    }

    func test_otherDrugNotInPatientList_returnsEmpty() {
        // warfarin + ibuprofen exists, but ibuprofen isn't in this regimen.
        let warfarin = med("Warfarin")
        XCTAssertTrue(service.interactionsFor(medication: warfarin, in: [warfarin, med("Metformin")]).isEmpty,
                      "an interaction must not fire unless both participants are present")
    }

    func test_allInteractionsFor_deduplicatesAndFindsEveryPair() {
        let all = service.allInteractionsFor(patient: [med("Warfarin"), med("Aspirin"), med("Ibuprofen")])
        XCTAssertEqual(all.count, Set(all.map(\.id)).count, "no duplicate ids")
        // warfarin+aspirin, warfarin+ibuprofen, aspirin+ibuprofen.
        XCTAssertEqual(Set(all.map(\.id)),
                       [pairID("warfarin", "aspirin"),
                        pairID("warfarin", "ibuprofen"),
                        pairID("aspirin", "ibuprofen")])
    }

    func test_languageSwitch_loadsPunjabiCorpus() {
        let pa = DrugInteractionService(bundle: .main, language: "pa")
        let warfarin = med("Warfarin")
        let paHits = pa.interactionsFor(medication: warfarin, in: [warfarin, med("Aspirin")])
        let enHits = service.interactionsFor(medication: warfarin, in: [warfarin, med("Aspirin")])
        XCTAssertFalse(paHits.isEmpty)
        XCTAssertNotEqual(paHits.first?.description, enHits.first?.description,
                          "the Punjabi corpus must return Punjabi text, not English")
    }

    func test_englishInteraction_lookupByID() {
        let id = pairID("warfarin", "aspirin")
        XCTAssertEqual(service.englishInteraction(id: id)?.id, id)
        XCTAssertNil(service.englishInteraction(id: "nope|nothing"))
    }
}
