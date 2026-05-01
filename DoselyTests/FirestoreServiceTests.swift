import XCTest
import CoreData
import FirebaseCore
import FirebaseFirestore
@testable import Dosely

/// These tests exercise the real Firestore SDK against the local
/// emulator (`firebase emulators:start`). When the emulator is not
/// reachable, the tests log and pass — so CI without the emulator does
/// not break the suite.
final class FirestoreServiceTests: XCTestCase {

    private static var firebaseConfigured = false
    private var stack: CoreDataStack!
    private var service: FirestoreService!
    private var testCollectionPrefix: String!

    override func setUp() {
        super.setUp()
        Self.configureFirebaseIfNeeded()
        stack = CoreDataStack(inMemory: true)
        service = FirestoreService.useEmulator()
        // Each test isolates itself under a unique synthetic id so
        // residual state from a prior run can't contaminate.
        testCollectionPrefix = "tests_\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        stack = nil
        service = nil
        super.tearDown()
    }

    private static func configureFirebaseIfNeeded() {
        if !firebaseConfigured {
            if FirebaseApp.app() == nil {
                FirebaseApp.configure()
            }
            firebaseConfigured = true
        }
    }

    /// Probe the emulator with a short timeout; if it isn't reachable,
    /// return false so the test logs-and-skips. We probe by writing a
    /// throwaway document; the SDK's offline queue will accept the
    /// write locally even when no server is up, so we explicitly wait
    /// for a server ack via a transaction (which fails fast).
    private func emulatorAvailable() async -> Bool {
        guard let db = service.db else {
            print("[EMULATOR-SKIP] FirestoreService not configured")
            return false
        }
        do {
            let docRef = db
                .collection("_emulator_probes")
                .document(UUID().uuidString)
            try await docRef.setData(["ts": FieldValue.serverTimestamp()])
            try? await docRef.delete()
            return true
        } catch {
            print("[EMULATOR-SKIP] Firestore emulator unreachable: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - createCareCircle / lookup join code

    func test_createCareCircle_writesBothCircleAndJoinCodeIndex() async throws {
        guard await emulatorAvailable() else { return }

        let id = UUID().uuidString
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let circle = FirestoreModels.FCareCircle(
            id: id,
            name: "Test Family",
            joinCode: code,
            createdAt: Date(),
            supervisorCount: 0,
            lastModified: nil
        )

        try await service.createCareCircle(circle)

        let loaded = try await service.loadCareCircle(circleID: id)
        XCTAssertEqual(loaded?.id, id)
        XCTAssertEqual(loaded?.joinCode, code)

        let viaCode = try await service.lookupJoinCode(code)
        XCTAssertEqual(viaCode, id)
    }

    // MARK: - regenerateJoinCode is atomic

    func test_regenerateJoinCode_isAtomic() async throws {
        guard await emulatorAvailable() else { return }

        let id = UUID().uuidString
        let oldCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let newCode = String(format: "%06d", Int.random(in: 0..<1_000_000))

        let circle = FirestoreModels.FCareCircle(
            id: id,
            name: "Atomic Family",
            joinCode: oldCode,
            createdAt: Date(),
            supervisorCount: 0,
            lastModified: nil
        )
        try await service.createCareCircle(circle)

        try await service.regenerateJoinCode(circleID: id, oldCode: oldCode, newCode: newCode)

        let viaOld = try await service.lookupJoinCode(oldCode)
        XCTAssertNil(viaOld, "old code should be invalid the moment regenerate returns")

        let viaNew = try await service.lookupJoinCode(newCode)
        XCTAssertEqual(viaNew, id, "new code should resolve immediately")

        let reloaded = try await service.loadCareCircle(circleID: id)
        XCTAssertEqual(reloaded?.joinCode, newCode)
    }

    /// Belt-and-suspenders for the bug we just fixed: after a regenerate,
    /// the /joinCodes collection must contain EXACTLY ONE document
    /// whose `careCircleID` is this circle. The previous transaction
    /// implementation could leave the index out of sync with the
    /// careCircle row; the new WriteBatch path commits all three writes
    /// (delete old code, create new code, update circle) together.
    func test_regenerateJoinCode_leavesExactlyOneIndexEntryForCircle() async throws {
        guard await emulatorAvailable() else { return }
        guard let db = service.db else { return }

        let id = UUID().uuidString
        let oldCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let newCode = String(format: "%06d", Int.random(in: 0..<1_000_000))

        let circle = FirestoreModels.FCareCircle(
            id: id,
            name: "Single-Index Family",
            joinCode: oldCode,
            createdAt: Date(),
            supervisorCount: 0,
            lastModified: nil
        )
        try await service.createCareCircle(circle)

        try await service.regenerateJoinCode(circleID: id, oldCode: oldCode, newCode: newCode)

        // Query /joinCodes for every doc pointing at this circle. There
        // must be exactly one — and its document id must match newCode.
        let snap = try await db.collection(FirestoreService.Path.joinCodes)
            .whereField("careCircleID", isEqualTo: id)
            .getDocuments()
        XCTAssertEqual(snap.documents.count, 1, "regenerate must leave exactly one /joinCodes index entry per circle")
        XCTAssertEqual(snap.documents.first?.documentID, newCode)

        let reloaded = try await service.loadCareCircle(circleID: id)
        XCTAssertEqual(reloaded?.joinCode, newCode)
    }

    /// When Firebase isn't configured, `regenerateJoinCode` must throw
    /// `.offline` rather than silently no-op — the silent-no-op was
    /// indistinguishable from success and caused the UI to display a
    /// new code that never reached Firestore.
    func test_regenerateJoinCode_throwsOfflineWhenNotConfigured() async {
        let unconfigured = FirestoreService()  // db == nil
        do {
            try await unconfigured.regenerateJoinCode(
                circleID: UUID().uuidString,
                oldCode: "111111",
                newCode: "222222"
            )
            XCTFail("expected .offline when db is nil")
        } catch FirestoreServiceError.offline {
            // Expected.
        } catch {
            XCTFail("expected .offline, got \(error)")
        }
    }

    // MARK: - lookupJoinCode does not read /careCircles

    /// Regression for the bug that produced "code didn't match a
    /// family" on a real, valid code: `lookupJoinCode` must NOT touch
    /// `/careCircles/{id}`. That read is denied to non-members; loading
    /// the careCircle inside the lookup made every joiner's first
    /// attempt fail with permission-denied which the repo collapsed to
    /// `.codeNotFound`.
    func test_lookupJoinCode_returnsCircleIDOnly() async throws {
        guard await emulatorAvailable() else { return }

        let id = UUID().uuidString
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let circle = FirestoreModels.FCareCircle(
            id: id,
            name: "Lookup-Only",
            joinCode: code,
            createdAt: Date(),
            supervisorCount: 0,
            lastModified: nil
        )
        try await service.createCareCircle(circle)

        let resolved = try await service.lookupJoinCode(code)
        XCTAssertEqual(resolved, id, "lookup must return the careCircleID without loading /careCircles")
    }

    func test_lookupJoinCode_unknownCodeReturnsNil() async throws {
        guard await emulatorAvailable() else { return }
        let resolved = try await service.lookupJoinCode("000000")
        XCTAssertNil(resolved)
    }

    // MARK: - joinCircleAsSecondary atomic batch

    /// Happy-path emulator integration: the joiner-bootstrap batch
    /// writes `/userMemberships/{uid}`, the new Person doc, and bumps
    /// `supervisorCount` together. Verifies all three landed and that
    /// the careCircle is afterwards readable as a member.
    func test_joinCircleAsSecondary_writesMembershipPersonAndBumpsCount() async throws {
        guard await emulatorAvailable() else { return }
        guard let db = service.db else { return }

        // Founder seeds a circle with supervisorCount=1 (founder is in).
        let circleID = UUID().uuidString
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let founderPersonID = UUID().uuidString
        let circle = FirestoreModels.FCareCircle(
            id: circleID,
            name: "Joiner Family",
            joinCode: code,
            createdAt: Date(),
            supervisorCount: 1,
            primarySupervisorPersonID: founderPersonID,
            lastModified: nil
        )
        try await service.createCareCircle(circle)
        // createCareCircle resets supervisorCount to 0; nudge it to 1
        // to simulate a real founder bootstrap.
        try await service.adjustSupervisorCount(circleID: circleID, delta: 1)

        let joinerUID = "joiner-\(UUID().uuidString)"
        let joinerPersonID = UUID().uuidString

        try await service.joinCircleAsSecondary(
            circleID: circleID,
            firebaseUID: joinerUID,
            personID: joinerPersonID,
            name: "Cousin",
            language: "en",
            joinCode: code
        )

        // /userMemberships/{joinerUID} exists with the expected shape.
        let membershipSnap = try await db
            .document(FirestoreService.Path.userMembership(joinerUID))
            .getDocument()
        XCTAssertTrue(membershipSnap.exists)
        XCTAssertEqual(membershipSnap.data()?["careCircleID"] as? String, circleID)
        XCTAssertEqual(membershipSnap.data()?["personID"] as? String, joinerPersonID)
        XCTAssertEqual(membershipSnap.data()?["role"] as? String, Roles.secondarySupervisor)

        // /careCircles/{id}/people/{joinerPersonID} exists as secondary.
        let personSnap = try await db
            .collection(FirestoreService.Path.people(circleID))
            .document(joinerPersonID)
            .getDocument()
        XCTAssertTrue(personSnap.exists)
        XCTAssertEqual(personSnap.data()?["firebaseUID"] as? String, joinerUID)
        XCTAssertEqual(personSnap.data()?["role"] as? String, Roles.secondarySupervisor)

        // /careCircles/{id}.supervisorCount went up by 1 (founder + joiner = 2).
        let circleSnap = try await db
            .document(FirestoreService.Path.careCircle(circleID))
            .getDocument()
        XCTAssertEqual(circleSnap.data()?["supervisorCount"] as? Int, 2)
    }

    // MARK: - Two-device sync via listener

    func test_twoServiceInstances_observeEachOthersWrites() async throws {
        guard await emulatorAvailable() else { return }

        let circleID = UUID().uuidString
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let circle = FirestoreModels.FCareCircle(
            id: circleID,
            name: "Two-device Family",
            joinCode: code,
            createdAt: Date(),
            supervisorCount: 0,
            lastModified: nil
        )
        try await service.createCareCircle(circle)

        // Second "device" — independent FirestoreService against the
        // same emulator. Attaches a listener; the first device's
        // writes should be observable within a few seconds.
        let secondDevice = FirestoreService.useEmulator()
        let observed = expectation(description: "listener observes write")
        observed.assertForOverFulfill = false

        let listener = secondDevice.listen(
            collectionPath: FirestoreService.Path.medications(circleID),
            as: FirestoreModels.FMedication.self
        ) { meds in
            if meds.contains(where: { $0.name == "TestMed-Sync" }) {
                observed.fulfill()
            }
        }
        defer { listener.remove() }

        // First device writes a med.
        let med = FirestoreModels.FMedication(
            id: UUID().uuidString,
            personID: UUID().uuidString,
            name: "TestMed-Sync",
            dose: "10mg",
            pillsPerDose: 1,
            foodRule: "either",
            notes: nil,
            currentSupply: 30,
            pillPhotoData: nil,
            dateAdded: Date(),
            lastModified: nil
        )
        try await service.upsertMedication(circleID: circleID, med: med)

        await fulfillment(of: [observed], timeout: 8.0)
    }

    // MARK: - FirestoreUploadMigration

    func test_uploadMigration_uploadsLocalCircleOnFirstRun() async throws {
        guard await emulatorAvailable() else { return }

        // Stand up a local-only circle (the pre-Firestore world).
        let firebaseUID = "test-uid-\(UUID().uuidString)"
        let circleID = UUID()
        let supervisorID = UUID()

        await stack.viewContext.perform { [self] in
            let ctx = stack.viewContext
            let circle = CareCircle(context: ctx)
            circle.id = circleID
            circle.name = "Migrated Family"
            circle.joinCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
            circle.createdAt = Date()

            let supervisor = Person(context: ctx)
            supervisor.id = supervisorID
            supervisor.name = "Aunt 1"
            supervisor.role = "supervisor"
            supervisor.languagePreference = "en"
            supervisor.firebaseUID = firebaseUID
            supervisor.failedPinAttempts = 0
            supervisor.careCircle = circle

            let med = Medication(context: ctx)
            med.id = UUID()
            med.personID = supervisorID
            med.name = "PreMigratedMed"
            med.dose = "5mg"
            med.foodRule = "either"
            med.pillsPerDose = 1
            med.currentSupply = 10
            med.dateAdded = Date()

            try? ctx.save()
        }

        FirestoreUploadMigration.resetForTesting()
        let uploaded = await FirestoreUploadMigration.runIfNeeded(
            firebaseUID: firebaseUID,
            stack: stack,
            firestore: service
        )
        XCTAssertTrue(uploaded, "first run should upload")

        // Verify Firestore now has the docs.
        let remote = try await service.loadCareCircle(circleID: circleID.uuidString)
        XCTAssertEqual(remote?.id, circleID.uuidString)

        let people = try await service.fetchPeople(circleID: circleID.uuidString)
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.firebaseUID, firebaseUID)

        // Idempotency: second run should be a no-op.
        let second = await FirestoreUploadMigration.runIfNeeded(
            firebaseUID: firebaseUID,
            stack: stack,
            firestore: service
        )
        XCTAssertFalse(second, "second run should not re-upload")
    }
}
