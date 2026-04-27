import CoreData
import XCTest
@testable import Dosely

final class CareCircleRepositoryTests: XCTestCase {
    var stack: CoreDataStack!
    var repo: CareCircleRepository!
    var personRepo: PersonRepository!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        repo = CareCircleRepository(stack: stack)
        personRepo = PersonRepository(stack: stack)
    }

    override func tearDown() {
        stack = nil; repo = nil; personRepo = nil
        super.tearDown()
    }

    func testCreateCareCircleAlsoCreatesSupervisor() async {
        let circle = await repo.createCareCircle(
            name: "Smith Family", foundingSupervisorFirebaseUID: "abc", founderName: "Joe"
        )
        XCTAssertEqual(circle.name, "Smith Family")
        XCTAssertEqual(circle.joinCode?.count, 6)

        let supervisor = await personRepo.fetchSupervisor(firebaseUID: "abc")
        XCTAssertNotNil(supervisor)
        XCTAssertEqual(supervisor?.role, "supervisor")
        XCTAssertEqual(supervisor?.careCircle?.id, circle.id)
    }

    func testJoinCodeIsUniqueAcross1000Generations() async {
        // Pure RNG check on the generator — not on the dedup loop, but the
        // collision probability over 1000 6-digit codes is small enough that
        // a duplicate strongly suggests a bug.
        var seen = Set<String>()
        for _ in 0..<1000 {
            let code = CareCircleRepository.randomCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { $0.isNumber })
            seen.insert(code)
        }
        // Probability of any duplicate in 1000 draws from 1M pool is ~39%
        // by the birthday formula. Allow a few collisions but reject if the
        // generator is obviously broken (e.g. < 950 unique).
        XCTAssertGreaterThan(seen.count, 950, "RNG looks degenerate")
    }

    func testJoinCareCircleSucceedsWithValidCode() async {
        let circle = await repo.createCareCircle(
            name: "Alpha", foundingSupervisorFirebaseUID: "founder", founderName: "F"
        )
        let code = circle.joinCode!

        let result = await repo.joinCareCircle(
            code: code, asSupervisorWithFirebaseUID: "joiner",
            name: "Joiner", language: "en"
        )
        switch result {
        case .success(let joined):
            XCTAssertEqual(joined.id, circle.id)
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }

        let people = await personRepo.fetchAllPeople(in: circle.id!)
        XCTAssertEqual(people.count, 2)
    }

    /// Mirrors the prompt's repro scenario verbatim: TestPerson 1 creates
    /// a circle, the test reads back the joinCode, TestPerson 2 calls
    /// joinCareCircle with the *exact* same string. Catches any latent
    /// encoding / casing / whitespace bug at the data layer.
    func testRoundTrippedJoinCodeMatchesByteForByte() async {
        let circle = await repo.createCareCircle(
            name: "Roundtrip", foundingSupervisorFirebaseUID: "p1", founderName: "P1"
        )
        let asWritten = circle.joinCode ?? ""
        XCTAssertEqual(asWritten.count, 6, "joinCode must be 6 digits")
        XCTAssertTrue(asWritten.allSatisfy { $0.isNumber })

        let result = await repo.joinCareCircle(
            code: asWritten, asSupervisorWithFirebaseUID: "p2",
            name: "P2", language: "en"
        )
        if case .failure(let error) = result {
            XCTFail("Round-trip lookup failed with \(error)")
        }
    }

    /// Real-world copy-paste variant: a user pastes the code with
    /// surrounding whitespace from a text message. The data layer must
    /// trim before comparison so the obvious case still works.
    func testJoinCareCircleAcceptsCodeWithSurroundingWhitespace() async {
        let circle = await repo.createCareCircle(
            name: "WS", foundingSupervisorFirebaseUID: "p1", founderName: "P1"
        )
        let code = circle.joinCode ?? ""
        let pasted = "  \(code)\n"
        let result = await repo.joinCareCircle(
            code: pasted, asSupervisorWithFirebaseUID: "p2",
            name: "P2", language: "en"
        )
        if case .failure(let error) = result {
            XCTFail("Whitespace-padded code should succeed, got \(error)")
        }
    }

    /// Forward-looking insurance: codes are digit-only today, but if a
    /// future generator ever produces letters, the comparison should be
    /// case-insensitive on both sides.
    func testJoinCareCircleAcceptsAlternateCasingDefensively() async {
        // We can't easily seed a circle with letters in joinCode through
        // the public API (uniqueJoinCode is digit-only), so we exercise
        // the normalization by mutating the stored value directly. This
        // proves the *comparison* is case-insensitive — the generator's
        // alphabet is a separate concern.
        let circle = await repo.createCareCircle(
            name: "Case", foundingSupervisorFirebaseUID: "p1", founderName: "P1"
        )
        await stack.viewContext.perform {
            circle.joinCode = "abc123"
            try? self.stack.viewContext.save()
        }
        let result = await repo.joinCareCircle(
            code: "ABC123", asSupervisorWithFirebaseUID: "p2",
            name: "P2", language: "en"
        )
        if case .failure(let error) = result {
            XCTFail("Mixed-case code should succeed, got \(error)")
        }
    }

    func testJoinCareCircleFailsWithBadCode() async {
        let result = await repo.joinCareCircle(
            code: "999999", asSupervisorWithFirebaseUID: "x",
            name: "X", language: "en"
        )
        XCTAssertEqual(result, .failure(.codeNotFound))
    }

    func testJoinCareCircleRejectsAlreadyMember() async {
        let circle = await repo.createCareCircle(
            name: "X", foundingSupervisorFirebaseUID: "founder", founderName: "F"
        )
        let result = await repo.joinCareCircle(
            code: circle.joinCode!, asSupervisorWithFirebaseUID: "founder",
            name: "F", language: "en"
        )
        XCTAssertEqual(result, .failure(.alreadyMember))
    }

    func testRegenerateJoinCodeChangesIt() async {
        let circle = await repo.createCareCircle(
            name: "X", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        let original = circle.joinCode
        let newCode = await repo.regenerateJoinCode(careCircleID: circle.id!)
        XCTAssertNotNil(newCode)
        XCTAssertNotEqual(newCode, original)
    }

    func testRenameCircleUpdatesName() async {
        let circle = await repo.createCareCircle(
            name: "Original", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        let ok = await repo.renameCircle(careCircleID: circle.id!, newName: "Renamed")
        XCTAssertTrue(ok)
        let refreshed = await repo.fetchCareCircle(id: circle.id!)
        XCTAssertEqual(refreshed?.name, "Renamed")
    }

    func testRenameCircleRejectsBlankName() async {
        let circle = await repo.createCareCircle(
            name: "Original", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        let ok = await repo.renameCircle(careCircleID: circle.id!, newName: "   ")
        XCTAssertFalse(ok)
        let refreshed = await repo.fetchCareCircle(id: circle.id!)
        XCTAssertEqual(refreshed?.name, "Original")
    }
}
