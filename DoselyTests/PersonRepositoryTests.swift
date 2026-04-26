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
        personRepo = PersonRepository(stack: stack)
        careCircleRepo = CareCircleRepository(stack: stack)
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

    func testCreateDeviceClientHashesPin() async {
        let client = await personRepo.createDeviceClient(
            name: "Grandma", photoData: nil, pinPlaintext: "1234",
            language: "pa", in: circle
        )
        XCTAssertEqual(client.role, "device_client")
        XCTAssertNotNil(client.pinHash)
        XCTAssertNotNil(client.pinSalt)
        XCTAssertNotEqual(client.pinHash, "1234", "PIN must never round-trip plaintext")
    }

    func testVerifyPinSuccess() async {
        let client = await personRepo.createDeviceClient(
            name: "Bibi", photoData: nil, pinPlaintext: "5678",
            language: "en", in: circle
        )
        let result = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "5678")
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.lockoutTriggered)
    }

    func testVerifyPinFailureIncrementsCounter() async {
        let client = await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "0000",
            language: "en", in: circle
        )
        let firstFail = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "9999")
        XCTAssertFalse(firstFail.verified)
        XCTAssertFalse(firstFail.lockoutTriggered)

        let refreshed = await personRepo.fetchPerson(id: client.id!)
        XCTAssertEqual(refreshed?.failedPinAttempts, 1)
    }

    func testThreeWrongPinsTriggersLockout() async {
        let client = await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "0000",
            language: "en", in: circle
        )
        _ = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "1111")
        _ = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "2222")
        let third = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "3333")
        XCTAssertTrue(third.lockoutTriggered)
    }

    func testSuccessfulPinResetsFailureCounter() async {
        let client = await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "1234",
            language: "en", in: circle
        )
        _ = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "9999")
        _ = await personRepo.verifyPin(personID: client.id!, pinPlaintext: "1234")
        let refreshed = await personRepo.fetchPerson(id: client.id!)
        XCTAssertEqual(refreshed?.failedPinAttempts, 0)
    }

    func testResetPinRequiresSupervisorInSameCircle() async throws {
        let client = await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "1111",
            language: "en", in: circle
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
        let client = await personRepo.createManagedClient(
            name: "Bibi", photoData: nil, language: "pa", in: circle
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
        let client = await personRepo.createDeviceClient(
            name: "X", photoData: nil, pinPlaintext: "1234",
            language: "en", in: circle
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
        let client = await personRepo.createManagedClient(
            name: "Y", photoData: nil, language: "en", in: circle
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

    func testRemoveCrossCircleRefused() async {
        let client = await personRepo.createManagedClient(
            name: "X", photoData: nil, language: "en", in: circle
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
}
