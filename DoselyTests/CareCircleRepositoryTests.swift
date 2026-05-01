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
        // Explicit no-op FirestoreService isolates the test from the
        // shared singleton: when DoselyApp has already configured Firebase
        // (which happens whenever the host app launches under Xcode), the
        // shared service points at production Firestore and unauthenticated
        // writes fail with permission_denied — leaving Core Data in sync
        // but the Firestore lookup path empty. Wiring a no-op service makes
        // the join + regenerate paths exercise the Core Data fallback.
        let noFirestore = FirestoreService()
        repo = CareCircleRepository(stack: stack, firestore: noFirestore)
        personRepo = PersonRepository(stack: stack, firestore: noFirestore)
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
        XCTAssertEqual(supervisor?.role, Roles.primarySupervisor,
                       "founder of a fresh circle is the primary supervisor")
        XCTAssertEqual(supervisor?.careCircle?.id, circle.id)
        XCTAssertEqual(circle.primarySupervisorPersonID, supervisor?.id,
                       "CareCircle.primarySupervisorPersonID must point at the founder")
    }

    func testJoinCareCircleMakesJoinerSecondary() async {
        let circle = await repo.createCareCircle(
            name: "Family", foundingSupervisorFirebaseUID: "founder", founderName: "F"
        )
        let result = await repo.joinCareCircle(
            code: circle.joinCode!,
            asSupervisorWithFirebaseUID: "joiner",
            name: "Joiner",
            language: "en"
        )
        guard case .success = result else {
            XCTFail("join failed"); return
        }
        let joiner = await personRepo.fetchSupervisor(firebaseUID: "joiner")
        XCTAssertEqual(joiner?.role, Roles.secondarySupervisor,
                       "new joiners are read-only secondary supervisors")
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

    /// With Firestore unconfigured the regenerate must throw `.offline`
    /// rather than silently update local Core Data — the previous
    /// "optimistic local write" behavior was the bug that produced UI
    /// codes that didn't exist on the server. The happy-path "new code
    /// differs from old" assertion lives in
    /// `FirestoreServiceTests.test_regenerateJoinCode_isAtomic`, which
    /// runs against the emulator.
    func testRegenerateJoinCodeRequiresFirestore() async {
        let circle = await repo.createCareCircle(
            name: "X", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        let original = circle.joinCode
        let founder = await personRepo.fetchSupervisor(firebaseUID: "f")!
        do {
            _ = try await repo.regenerateJoinCode(
                careCircleID: circle.id!, actorPersonID: founder.id!
            )
            XCTFail("Expected .offline when Firestore is unconfigured")
        } catch let err as CareCircleEditError {
            XCTAssertEqual(err, .offline)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        // Local Core Data must NOT have been mutated.
        let refreshed = await repo.fetchCareCircle(id: circle.id!)
        XCTAssertEqual(refreshed?.joinCode, original)
    }

    func testRegenerateJoinCodeRefusesSecondary() async {
        let circle = await repo.createCareCircle(
            name: "X", foundingSupervisorFirebaseUID: "primary", founderName: "P"
        )
        _ = await repo.joinCareCircle(
            code: circle.joinCode!,
            asSupervisorWithFirebaseUID: "secondary",
            name: "S"
        )
        let secondary = await personRepo.fetchSupervisor(firebaseUID: "secondary")!
        do {
            _ = try await repo.regenerateJoinCode(
                careCircleID: circle.id!, actorPersonID: secondary.id!
            )
            XCTFail("Expected permissionDenied")
        } catch let err as CareCircleEditError {
            XCTAssertEqual(err, .permissionDenied)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testRenameCircleUpdatesName() async throws {
        let circle = await repo.createCareCircle(
            name: "Original", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        let founder = await personRepo.fetchSupervisor(firebaseUID: "f")!
        try await repo.renameCircle(
            careCircleID: circle.id!, newName: "Renamed", actorPersonID: founder.id!
        )
        let refreshed = await repo.fetchCareCircle(id: circle.id!)
        XCTAssertEqual(refreshed?.name, "Renamed")
    }

    func testRenameCircleRejectsBlankName() async {
        let circle = await repo.createCareCircle(
            name: "Original", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        let founder = await personRepo.fetchSupervisor(firebaseUID: "f")!
        do {
            try await repo.renameCircle(
                careCircleID: circle.id!, newName: "   ", actorPersonID: founder.id!
            )
            XCTFail("Expected invalidName")
        } catch let err as CareCircleEditError {
            XCTAssertEqual(err, .invalidName)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        let refreshed = await repo.fetchCareCircle(id: circle.id!)
        XCTAssertEqual(refreshed?.name, "Original")
    }

    func testRenameCircleRefusesSecondary() async {
        let circle = await repo.createCareCircle(
            name: "Original", foundingSupervisorFirebaseUID: "primary", founderName: "P"
        )
        _ = await repo.joinCareCircle(
            code: circle.joinCode!,
            asSupervisorWithFirebaseUID: "secondary",
            name: "S"
        )
        let secondary = await personRepo.fetchSupervisor(firebaseUID: "secondary")!
        do {
            try await repo.renameCircle(
                careCircleID: circle.id!, newName: "Hijacked", actorPersonID: secondary.id!
            )
            XCTFail("Expected permissionDenied")
        } catch let err as CareCircleEditError {
            XCTAssertEqual(err, .permissionDenied)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Leave circle

    func testLeaveCircleAsLastSupervisorReturnsLastSupervisor() async {
        let circle = await repo.createCareCircle(
            name: "Solo", foundingSupervisorFirebaseUID: "only", founderName: "Only"
        )
        let supervisor = await personRepo.fetchSupervisor(firebaseUID: "only")!
        let result = await repo.leaveCircle(supervisorPersonID: supervisor.id!)
        if case .failure(let error) = result {
            XCTAssertEqual(error, .lastSupervisor)
        } else {
            XCTFail("expected lastSupervisor failure")
        }

        let stillThere = await personRepo.fetchSupervisor(firebaseUID: "only")
        XCTAssertNotNil(stillThere, "supervisor row must not be deleted on a refused leave")
        _ = circle
    }

    func testSecondaryCanLeaveWhenPrimaryRemains() async {
        // Founder is the primary; the joiner is a secondary. The
        // secondary can leave directly because the primary stays
        // behind to keep the circle writable.
        let circle = await repo.createCareCircle(
            name: "Pair", foundingSupervisorFirebaseUID: "founder", founderName: "Founder"
        )
        _ = await repo.joinCareCircle(
            code: circle.joinCode!,
            asSupervisorWithFirebaseUID: "second",
            name: "Second"
        )
        let second = await personRepo.fetchSupervisor(firebaseUID: "second")!
        let leave = await repo.leaveCircle(supervisorPersonID: second.id!)
        if case .failure(let error) = leave {
            XCTFail("Expected success, got \(error)")
        }
        let goneSecondary = await personRepo.fetchSupervisor(firebaseUID: "second")
        XCTAssertNil(goneSecondary)
        let founder = await personRepo.fetchSupervisor(firebaseUID: "founder")
        XCTAssertNotNil(founder)
    }

    func testPrimaryCannotLeaveDirectlyWhenSecondaryExists() async {
        // The primary must promote the secondary first; trying to leave
        // before promoting returns the new `primaryMustPromoteFirst`.
        let circle = await repo.createCareCircle(
            name: "Pair", foundingSupervisorFirebaseUID: "founder", founderName: "Founder"
        )
        _ = await repo.joinCareCircle(
            code: circle.joinCode!,
            asSupervisorWithFirebaseUID: "second",
            name: "Second"
        )
        let founder = await personRepo.fetchSupervisor(firebaseUID: "founder")!
        let leave = await repo.leaveCircle(supervisorPersonID: founder.id!)
        if case .failure(let err) = leave {
            XCTAssertEqual(err, .primaryMustPromoteFirst)
        } else {
            XCTFail("Expected primaryMustPromoteFirst")
        }
        // Founder still in the circle.
        let stillThere = await personRepo.fetchSupervisor(firebaseUID: "founder")
        XCTAssertNotNil(stillThere)
    }

    func testPrimaryCanLeaveAfterPromotingSecondary() async throws {
        let circle = await repo.createCareCircle(
            name: "Pair", foundingSupervisorFirebaseUID: "founder", founderName: "Founder"
        )
        _ = await repo.joinCareCircle(
            code: circle.joinCode!,
            asSupervisorWithFirebaseUID: "second",
            name: "Second"
        )
        let founder = await personRepo.fetchSupervisor(firebaseUID: "founder")!
        let second = await personRepo.fetchSupervisor(firebaseUID: "second")!

        try await personRepo.promoteToPrimary(
            targetPersonID: second.id!, actorPersonID: founder.id!
        )
        // After promotion the founder is now a secondary and may leave.
        let leave = await repo.leaveCircle(supervisorPersonID: founder.id!)
        if case .failure(let error) = leave {
            XCTFail("Expected success after promotion, got \(error)")
        }
        let goneFounder = await personRepo.fetchSupervisor(firebaseUID: "founder")
        XCTAssertNil(goneFounder)
        let nowPrimary = await personRepo.fetchSupervisor(firebaseUID: "second")
        XCTAssertEqual(nowPrimary?.role, Roles.primarySupervisor)
    }

    func testLeaveThenJoinAnotherCircleCreatesFreshSupervisorRow() async {
        // Two distinct circles; same Firebase UID jumps between them.
        let circleA = await repo.createCareCircle(
            name: "A", foundingSupervisorFirebaseUID: "A1", founderName: "A1"
        )
        // Add a second supervisor to A so the jumper isn't the last one.
        _ = await repo.joinCareCircle(
            code: circleA.joinCode!,
            asSupervisorWithFirebaseUID: "switcher",
            name: "Jumper"
        )
        let switcherInA = await personRepo.fetchSupervisor(firebaseUID: "switcher")!
        let switcherInAID = switcherInA.id!

        let circleB = await repo.createCareCircle(
            name: "B", foundingSupervisorFirebaseUID: "B1", founderName: "B1"
        )

        // Leave A
        let leave = await repo.leaveCircle(supervisorPersonID: switcherInAID)
        if case .failure = leave { XCTFail("leave A failed") }

        // Join B
        let join = await repo.joinCareCircle(
            code: circleB.joinCode!,
            asSupervisorWithFirebaseUID: "switcher",
            name: "Jumper"
        )
        guard case .success = join else { XCTFail("join B failed"); return }

        // Fresh Person row in B; old id is gone.
        let switcherInB = await personRepo.fetchSupervisor(firebaseUID: "switcher")
        XCTAssertNotNil(switcherInB)
        XCTAssertEqual(switcherInB?.careCircle?.id, circleB.id)
        XCTAssertNotEqual(switcherInB?.id, switcherInAID,
                          "rejoining must produce a new Person row, by design")
    }

    func testLeaveCircleFromUnknownPersonReturnsNotFound() async {
        let result = await repo.leaveCircle(supervisorPersonID: UUID())
        if case .failure(let error) = result {
            XCTAssertEqual(error, .notFound)
        } else {
            XCTFail("expected notFound failure")
        }
    }
}
