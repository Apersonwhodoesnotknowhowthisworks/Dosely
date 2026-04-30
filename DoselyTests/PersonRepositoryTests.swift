import CoreData
import XCTest
@testable import Dosely

final class PersonRepositoryTests: XCTestCase {
    var stack: CoreDataStack!
    var personRepo: PersonRepository!
    var careCircleRepo: CareCircleRepository!
    var circle: CareCircle!
    var supervisor: Person!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        // See `CareCircleRepositoryTests.setUp` for why a no-op
        // FirestoreService is wired in explicitly.
        let noFirestore = FirestoreService()
        personRepo = PersonRepository(stack: stack, firestore: noFirestore)
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        circle = await careCircleRepo.createCareCircle(
            name: "Test", foundingSupervisorFirebaseUID: "uid-1", founderName: "Founder"
        )
        supervisor = await personRepo.fetchSupervisor(firebaseUID: "uid-1")
    }

    override func tearDown() {
        stack = nil; personRepo = nil; careCircleRepo = nil
        circle = nil; supervisor = nil
        super.tearDown()
    }

    func testCreateDeviceClientHashesPin() async throws {
        let client = try await personRepo.createDeviceClient(
            name: "Grandma", photoData: nil, pinPlaintext: "1234",
            language: "pa", in: circle, actorPersonID: supervisor.id!
        )
        XCTAssertEqual(client.role, "device_client")
        XCTAssertNotNil(client.pinHash)
        XCTAssertNotNil(client.pinSalt)
        XCTAssertNotEqual(client.pinHash, "1234", "PIN must never round-trip plaintext")
    }

    func testVerifyPinSuccess() async throws {
        let client = try await personRepo.createDeviceClient(
            name: "Bibi", photoData: nil, pinPlaintext: "5678",
            language: "en", in: circle, actorPersonID: supervisor.id!
        )
        let result = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "5678")
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.lockoutTriggered)
    }

    func testVerifyPinFailureIncrementsCounter() async throws {
        let client = try await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "0000",
            language: "en", in: circle, actorPersonID: supervisor.id!
        )
        let firstFail = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "9999")
        XCTAssertFalse(firstFail.verified)
        XCTAssertFalse(firstFail.lockoutTriggered)

        let refreshed = await personRepo.fetchPerson(id: client.id!)
        XCTAssertEqual(refreshed?.failedPinAttempts, 1)
    }

    func testThreeWrongPinsTriggersLockout() async throws {
        let client = try await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "0000",
            language: "en", in: circle, actorPersonID: supervisor.id!
        )
        _ = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "1111")
        _ = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "2222")
        let third = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "3333")
        XCTAssertTrue(third.lockoutTriggered)
    }

    func testSuccessfulPinResetsFailureCounter() async throws {
        let client = try await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "1234",
            language: "en", in: circle, actorPersonID: supervisor.id!
        )
        _ = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "9999")
        _ = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "1234")
        let refreshed = await personRepo.fetchPerson(id: client.id!)
        XCTAssertEqual(refreshed?.failedPinAttempts, 0)
    }

    func testResetPinRequiresSupervisorInSameCircle() async throws {
        let client = try await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "1111",
            language: "en", in: circle, actorPersonID: supervisor.id!
        )

        // Same-circle supervisor: succeeds.
        try await personRepo.resetPin(personID: client.id!,
                                      newPinPlaintext: "9999",
                                      actingSupervisorID: supervisor.id!)
        let ok = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "9999")
        XCTAssertTrue(ok.verified)

        // Different-circle supervisor: fails.
        let otherCircle = await careCircleRepo.createCareCircle(
            name: "Other", foundingSupervisorFirebaseUID: "uid-2", founderName: "Stranger"
        )
        let stranger = await personRepo.fetchSupervisor(firebaseUID: "uid-2")!
        do {
            try await personRepo.resetPin(personID: client.id!,
                                          newPinPlaintext: "0000",
                                          actingSupervisorID: stranger.id!)
            XCTFail("Expected permissionDenied")
        } catch let error as PersonRepositoryError {
            XCTAssertEqual(error, .permissionDenied)
        }
        _ = otherCircle
    }

    // MARK: - Role flip

    func testPromoteManagedClientToDeviceClientSetsPin() async throws {
        let client = try await personRepo.createManagedClient(
            name: "Bibi", photoData: nil, language: "pa", in: circle, actorPersonID: supervisor.id!
        )
        try await personRepo.updatePersonRole(personID: client.id!,
                                              newRole: "device_client",
                                              newPinPlaintext: "4321",
                                              actingSupervisorID: supervisor.id!)

        let refreshed = await personRepo.fetchPerson(id: client.id!)
        XCTAssertEqual(refreshed?.role, "device_client")
        let ok = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "4321")
        XCTAssertTrue(ok.verified)
    }

    func testDemoteDeviceClientToManagedClientClearsPin() async throws {
        let client = try await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "1234",
            language: "en", in: circle, actorPersonID: supervisor.id!
        )
        try await personRepo.updatePersonRole(personID: client.id!,
                                              newRole: "managed_client",
                                              newPinPlaintext: nil,
                                              actingSupervisorID: supervisor.id!)
        let refreshed = await personRepo.fetchPerson(id: client.id!)
        XCTAssertEqual(refreshed?.role, "managed_client")
        XCTAssertNil(refreshed?.pinHash)
        XCTAssertNil(refreshed?.pinSalt)
    }

    func testRoleFlipRefusesSupervisorTransitions() async {
        do {
            try await personRepo.updatePersonRole(personID: supervisor.id!,
                                                  newRole: "device_client",
                                                  newPinPlaintext: "0000",
                                                  actingSupervisorID: supervisor.id!)
            XCTFail("Expected invalidRoleTransition")
        } catch let error as PersonRepositoryError {
            XCTAssertEqual(error, .invalidRoleTransition)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Remove from circle

    func testRemoveClientDeletesPersonAndCascadesMedications() async throws {
        let client = try await personRepo.createManagedClient(
            name: "Y", photoData: nil, language: "en", in: circle, actorPersonID: supervisor.id!
        )
        // Capture the id up front — Core Data nils out properties after
        // the managed object turns into a fault on delete.
        let clientID = client.id!

        let medRepo = MedicationRepository(stack: stack)
        _ = try await medRepo.saveMedication(
            personID: clientID,
            actorPersonID: supervisor.id!,
            name: "Aspirin", dose: "10mg",
            pillsPerDose: 1, foodRule: "either", notes: nil,
            currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)]
        )

        try await personRepo.removePersonFromCircle(personID: clientID,
                                                    actingSupervisorID: supervisor.id!)

        let gone = await personRepo.fetchPerson(id: clientID)
        XCTAssertNil(gone)
        let meds = await medRepo.fetchAllMedications(for: clientID)
        XCTAssertTrue(meds.isEmpty)
    }

    func testRemoveLastSupervisorRefuses() async {
        do {
            try await personRepo.removePersonFromCircle(personID: supervisor.id!,
                                                        actingSupervisorID: supervisor.id!)
            XCTFail("Expected lastSupervisor")
        } catch let error as PersonRepositoryError {
            XCTAssertEqual(error, .lastSupervisor)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemoveCrossCircleRefused() async throws {
        let client = try await personRepo.createManagedClient(
            name: "X", photoData: nil, language: "en", in: circle, actorPersonID: supervisor.id!
        )
        let otherCircle = await careCircleRepo.createCareCircle(
            name: "Other", foundingSupervisorFirebaseUID: "uid-other", founderName: "Stranger"
        )
        let stranger = await personRepo.fetchSupervisor(firebaseUID: "uid-other")!
        do {
            try await personRepo.removePersonFromCircle(personID: client.id!,
                                                        actingSupervisorID: stranger.id!)
            XCTFail("Expected permissionDenied")
        } catch let error as PersonRepositoryError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        _ = otherCircle
    }

    // MARK: - Primary / secondary split

    /// Helper that adds a second supervisor to the test circle as a
    /// secondary, returning the new Person row.
    private func addSecondarySupervisor(uid: String, name: String) async -> Person {
        let result = await careCircleRepo.joinCareCircle(
            code: circle.joinCode!,
            asSupervisorWithFirebaseUID: uid,
            name: name
        )
        guard case .success = result else {
            XCTFail("setup join failed for \(uid)")
            return supervisor
        }
        return await personRepo.fetchSupervisor(firebaseUID: uid)!
    }

    func testFounderIsPrimaryAndCanWrite() async {
        XCTAssertEqual(supervisor.role, Roles.primarySupervisor)
        let isPrimary = await personRepo.isPrimary(personID: supervisor.id!)
        XCTAssertTrue(isPrimary)
        let canWrite = await personRepo.canWrite(actorPersonID: supervisor.id!)
        XCTAssertTrue(canWrite)
    }

    func testJoinerIsSecondaryAndCannotWrite() async {
        let secondary = await addSecondarySupervisor(uid: "second-uid", name: "Second")
        XCTAssertEqual(secondary.role, Roles.secondarySupervisor)
        let isPrimary = await personRepo.isPrimary(personID: secondary.id!)
        XCTAssertFalse(isPrimary)
        let canWrite = await personRepo.canWrite(actorPersonID: secondary.id!)
        XCTAssertFalse(canWrite)
    }

    func testSecondaryCanReadPeople() async {
        // Reads aren't gated locally — Core Data is open. The test
        // just confirms a secondary can resolve the same data the
        // primary sees. (Firestore-side read access for secondaries is
        // verified by tests/firestore_rules.test.ts.)
        _ = await addSecondarySupervisor(uid: "second-uid", name: "Second")
        let people = await personRepo.fetchAllPeople(in: circle.id!)
        XCTAssertEqual(people.count, 2)
    }

    func testSecondarySaveMedicationThrowsPermissionDenied() async {
        let secondary = await addSecondarySupervisor(uid: "second-uid", name: "Second")
        let medRepo = MedicationRepository(stack: stack)
        do {
            _ = try await medRepo.saveMedication(
                personID: supervisor.id!,
                actorPersonID: secondary.id!,
                name: "Blocked", dose: "1mg", pillsPerDose: 1, foodRule: "either",
                notes: nil, currentSupply: 1, pillPhotoData: nil
            )
            XCTFail("Expected permissionDenied")
        } catch let err as MedicationRepositoryError {
            XCTAssertEqual(err, .permissionDenied)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - promoteToPrimary

    func testPromoteToPrimarySwapsRoles() async throws {
        let secondary = await addSecondarySupervisor(uid: "second-uid", name: "Second")
        try await personRepo.promoteToPrimary(
            targetPersonID: secondary.id!, actorPersonID: supervisor.id!
        )

        let oldPrimary = await personRepo.fetchPerson(id: supervisor.id!)
        let newPrimary = await personRepo.fetchPerson(id: secondary.id!)
        XCTAssertEqual(oldPrimary?.role, Roles.secondarySupervisor)
        XCTAssertEqual(newPrimary?.role, Roles.primarySupervisor)

        let refreshedCircle = await careCircleRepo.fetchCareCircle(id: circle.id!)
        XCTAssertEqual(refreshedCircle?.primarySupervisorPersonID, secondary.id)
    }

    func testPromoteToPrimaryRefusesNonPrimaryCaller() async {
        let secondary = await addSecondarySupervisor(uid: "second-uid", name: "Second")
        // The secondary tries to promote themselves — the actor isn't
        // the current primary.
        do {
            try await personRepo.promoteToPrimary(
                targetPersonID: secondary.id!, actorPersonID: secondary.id!
            )
            XCTFail("Expected notCurrentPrimary")
        } catch let err as PersonRepositoryError {
            XCTAssertEqual(err, .notCurrentPrimary)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testPromoteToPrimaryRefusesNonSupervisorTarget() async {
        let client = try? await personRepo.createDeviceClient(
            name: "Grandpa", photoData: nil, pinPlaintext: "1234",
            language: "en", in: circle, actorPersonID: supervisor.id!
        )
        do {
            try await personRepo.promoteToPrimary(
                targetPersonID: client!.id!, actorPersonID: supervisor.id!
            )
            XCTFail("Expected invalidPromotionTarget")
        } catch let err as PersonRepositoryError {
            XCTAssertEqual(err, .invalidPromotionTarget)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testDemotedPrimaryCannotWriteAfterPromotion() async throws {
        let secondary = await addSecondarySupervisor(uid: "second-uid", name: "Second")
        try await personRepo.promoteToPrimary(
            targetPersonID: secondary.id!, actorPersonID: supervisor.id!
        )

        // The original supervisor is now a secondary. Their saveMedication
        // call must be rejected on the canWrite check.
        let medRepo = MedicationRepository(stack: stack)
        do {
            _ = try await medRepo.saveMedication(
                personID: secondary.id!,
                actorPersonID: supervisor.id!,
                name: "Forbidden", dose: "1mg", pillsPerDose: 1, foodRule: "either",
                notes: nil, currentSupply: 1, pillPhotoData: nil
            )
            XCTFail("Expected permissionDenied — caller is now secondary")
        } catch let err as MedicationRepositoryError {
            XCTAssertEqual(err, .permissionDenied)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testPromotedSecondaryCanWriteAfterPromotion() async throws {
        let secondary = await addSecondarySupervisor(uid: "second-uid", name: "Second")
        try await personRepo.promoteToPrimary(
            targetPersonID: secondary.id!, actorPersonID: supervisor.id!
        )

        let medRepo = MedicationRepository(stack: stack)
        let med = try await medRepo.saveMedication(
            personID: secondary.id!,
            actorPersonID: secondary.id!,
            name: "Allowed", dose: "1mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 1, pillPhotoData: nil
        )
        XCTAssertEqual(med.name, "Allowed")
    }
}
