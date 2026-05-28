import CoreData
import XCTest
@testable import Dosely

/// Tests for `MedicalIDRepository`. Wires the no-op `FirestoreService`
/// (db == nil) so `save` reliably throws `.offline` — that's the
/// regression bait: a save must NOT leak through to the local cache
/// when the remote write didn't land, matching the
/// `regenerateJoinCode` pattern.
final class MedicalIDRepositoryTests: XCTestCase {
    var stack: CoreDataStack!
    var personRepo: PersonRepository!
    var careCircleRepo: CareCircleRepository!
    var medicalIDRepo: MedicalIDRepository!
    var circle: CareCircle!
    var supervisor: Person!
    var grandpa: Person!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        let noFirestore = FirestoreService()
        personRepo = PersonRepository(stack: stack, firestore: noFirestore)
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        medicalIDRepo = MedicalIDRepository(stack: stack, firestore: noFirestore)
        circle = await careCircleRepo.createCareCircle(
            name: "T", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        supervisor = await personRepo.fetchSupervisor(firebaseUID: "f")
        grandpa = try await personRepo.createManagedClient(
            name: "Grandpa", photoData: nil, language: "en",
            in: circle, actorPersonID: supervisor.id!
        )
    }

    override func tearDown() {
        stack = nil; personRepo = nil; careCircleRepo = nil; medicalIDRepo = nil
        circle = nil; supervisor = nil; grandpa = nil
        super.tearDown()
    }

    // MARK: - Read

    func testFetchLocal_returnsNilForUnknownPerson() async {
        let result = await medicalIDRepo.fetchLocal(personID: UUID())
        XCTAssertNil(result)
    }

    func testFetchLocal_returnsAfterUpsert() async throws {
        // Use the codable upsert directly to side-step the Firestore-first
        // save path (which would throw .offline here).
        await stack.viewContext.perform { [self] in
            let f = FirestoreModels.FMedicalID(
                id: grandpa.id!.uuidString,
                personID: grandpa.id!.uuidString,
                dateOfBirth: nil,
                bloodType: "O+",
                allergies: ["Penicillin"],
                conditions: ["Hypertension"],
                emergencyContacts: [
                    FirestoreModels.FEmergencyContact(
                        name: "Aunt Bibi", relationship: "Daughter", phone: "555-0101"
                    )
                ],
                notes: "Uses a hearing aid",
                updatedAt: Date()
            )
            _ = f.upsert(in: stack.viewContext)
            try? stack.viewContext.save()
        }

        let row = await medicalIDRepo.fetchLocal(personID: grandpa.id!)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.bloodType, "O+")
        XCTAssertEqual(
            FirestoreModels.FMedicalID.decodeStringList(row?.allergiesJSON),
            ["Penicillin"]
        )
        XCTAssertEqual(row?.notes, "Uses a hearing aid")
    }

    // MARK: - Write

    /// Without Firestore, `save` MUST throw the repository's OWN
    /// `MedicalIDRepositoryError.offline` — not the underlying
    /// `FirestoreServiceError.offline` — and leave the local row
    /// untouched. Repositories translate the service error one-to-one
    /// per the error-collapse convention; leaking the lower-layer type
    /// would defeat the UI's branch-on-domain-case logic. Emergency
    /// responders look at this field — we don't claim a save landed
    /// when it didn't.
    func testSave_throwsOfflineAndLeavesLocalCacheUntouchedWhenFirestoreMissing() async {
        do {
            try await medicalIDRepo.save(
                personID: grandpa.id!,
                circleID: circle.id!,
                dateOfBirth: nil,
                bloodType: "B+",
                allergies: ["Latex"],
                conditions: [],
                emergencyContacts: [],
                notes: nil
            )
            XCTFail("expected MedicalIDRepositoryError.offline without a configured Firestore client")
        } catch let serviceError as FirestoreServiceError {
            XCTFail("""
                repository leaked the underlying \(serviceError) — it must \
                translate to MedicalIDRepositoryError per the error-collapse \
                convention (CLAUDE.md). The UI branches on the domain case.
                """)
        } catch MedicalIDRepositoryError.offline {
            // expected — the domain error, mapped one-to-one from
            // FirestoreServiceError.offline by save's catch chain.
        } catch {
            XCTFail("expected MedicalIDRepositoryError.offline, got \(error)")
        }

        let row = await medicalIDRepo.fetchLocal(personID: grandpa.id!)
        XCTAssertNil(row, "local mirror must not exist after a failed remote write")
    }

    /// All four `MedicalIDRepositoryError` cases must stay mutually
    /// distinct so `EditMedicalIDView` can branch each to its own
    /// copy. Mirrors `ErrorCollapseConventionTests` — collapsing two
    /// of these sends a supervisor chasing the wrong cause (a rules
    /// rejection messaged as "check your connection"). `save`'s catch
    /// chain maps each underlying `FirestoreServiceError` to the
    /// matching case here; this pins that those targets stay separable.
    func testMedicalIDRepositoryError_allFourCasesAreMutuallyDistinct() {
        let cases: [MedicalIDRepositoryError] = [
            .permissionDenied,
            .offline,
            .notFound,
            .unknown("rules rejected the write")
        ]
        for (i, lhs) in cases.enumerated() {
            for (j, rhs) in cases.enumerated() where i != j {
                XCTAssertNotEqual(
                    lhs, rhs,
                    "MedicalIDRepositoryError cases must stay distinct so EditMedicalIDView branches per case — see error-collapse convention (build_log April 30)."
                )
            }
        }
    }

    // MARK: - Round-trip via the codable shape

    /// Encodes a populated payload, decodes it, and asserts the
    /// fields survive the JSON encoding helpers — the allergies /
    /// conditions / emergency contacts all live in JSON strings on
    /// the Core Data row, and a bug in the encode/decode shape would
    /// silently drop data.
    func testJSONRoundTripPreservesEveryField() {
        let original = FirestoreModels.FMedicalID(
            id: UUID().uuidString,
            personID: UUID().uuidString,
            dateOfBirth: nil,
            bloodType: "A-",
            allergies: ["Peanuts", "Latex"],
            conditions: ["Asthma"],
            emergencyContacts: [
                FirestoreModels.FEmergencyContact(name: "A", relationship: "B", phone: "C"),
                FirestoreModels.FEmergencyContact(name: "D", relationship: "E", phone: "F")
            ],
            notes: "uses a hearing aid",
            updatedAt: Date()
        )

        let allergiesJSON = FirestoreModels.FMedicalID.encodeStringList(original.allergies)
        let conditionsJSON = FirestoreModels.FMedicalID.encodeStringList(original.conditions)
        let contactsJSON = FirestoreModels.FMedicalID.encodeContacts(original.emergencyContacts)

        XCTAssertEqual(
            FirestoreModels.FMedicalID.decodeStringList(allergiesJSON),
            original.allergies
        )
        XCTAssertEqual(
            FirestoreModels.FMedicalID.decodeStringList(conditionsJSON),
            original.conditions
        )
        XCTAssertEqual(
            FirestoreModels.FMedicalID.decodeContacts(contactsJSON),
            original.emergencyContacts
        )
    }

    // MARK: - Cascade delete from PersonRepository

    /// Removing a Person from the circle must wipe their MedicalID
    /// row locally. The Firestore-side delete is best-effort (it
    /// fires after the Person doc is gone) — the local mirror is
    /// what we can assert on here.
    func testRemovePersonFromCircle_cascadesToMedicalIDRow() async throws {
        // Capture up front: removePersonFromCircle deletes the grandpa
        // managed object, after which grandpa.id faults to nil and any
        // later grandpa.id! would crash.
        let grandpaID = grandpa.id!

        await stack.viewContext.perform { [self] in
            let f = FirestoreModels.FMedicalID(
                id: grandpaID.uuidString,
                personID: grandpaID.uuidString,
                dateOfBirth: nil,
                bloodType: "A+",
                allergies: [],
                conditions: [],
                emergencyContacts: [],
                notes: nil,
                updatedAt: Date()
            )
            _ = f.upsert(in: stack.viewContext)
            try? stack.viewContext.save()
        }

        try await personRepo.removePersonFromCircle(
            personID: grandpaID,
            actingSupervisorID: supervisor.id!
        )

        let row = await medicalIDRepo.fetchLocal(personID: grandpaID)
        XCTAssertNil(row,
                     "Person.medicalID has Cascade delete rule — removing the Person nukes the MedicalID")
    }
}
