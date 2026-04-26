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
}
