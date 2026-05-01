import XCTest
import CoreData
import FirebaseCore
import FirebaseFirestore
@testable import Dosely

/// Emulator integration tests for `OrphanCircleCleanupMigration`.
///
/// **Auth context.** These tests do not sign in via FirebaseAuth — like
/// the rest of the Swift Firestore tests, they piggyback on the iOS
/// SDK's "owner" token that the Firestore emulator treats as admin
/// access. The structural migration behaviour (find orphan candidates,
/// delete each candidate's subcollections + /joinCodes lookup + root
/// doc, leave the real circle alone, flip the UserDefaults flag) is
/// what's verified here. The rules-layer `isOrphanFounder` authority
/// check has its own dedicated coverage in
/// `tests/firestore_rules.test.ts` under "orphan-founder cleanup".
final class OrphanCircleCleanupMigrationTests: XCTestCase {

    private static var firebaseConfigured = false
    private var service: FirestoreService!

    override func setUp() {
        super.setUp()
        Self.configureFirebaseIfNeeded()
        service = FirestoreService.useEmulator()
        OrphanCircleCleanupMigration.resetForTesting()
    }

    override func tearDown() {
        service = nil
        OrphanCircleCleanupMigration.resetForTesting()
        super.tearDown()
    }

    private static func configureFirebaseIfNeeded() {
        if !firebaseConfigured {
            if FirebaseApp.app() == nil { FirebaseApp.configure() }
            firebaseConfigured = true
        }
    }

    private func emulatorAvailable() async -> Bool {
        guard let db = service.db else { return false }
        do {
            let docRef = db.collection("_emulator_probes").document(UUID().uuidString)
            try await docRef.setData(["ts": FieldValue.serverTimestamp()])
            try? await docRef.delete()
            return true
        } catch {
            print("[EMULATOR-SKIP] orphan tests: \(error.localizedDescription)")
            return false
        }
    }

    /// Pre-seed a careCircle complete with a /joinCodes lookup, a
    /// /userMemberships entry (when `withMembership` is true), and the
    /// founding supervisor's Person doc. `founderFirebaseUID` is what
    /// goes on the Person doc so the `isOrphanFounder` rules-layer
    /// check would resolve it to the same user when this is run under
    /// real auth. Returns the circle id and join code.
    private func seedCircle(
        founderFirebaseUID: String,
        withMembership: Bool
    ) async throws -> (circleID: String, joinCode: String, founderPersonID: String) {
        let circleID = UUID().uuidString
        let founderPersonID = UUID().uuidString
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let circle = FirestoreModels.FCareCircle(
            id: circleID,
            name: "Seeded",
            joinCode: code,
            createdAt: Date(),
            supervisorCount: 1,
            primarySupervisorPersonID: founderPersonID,
            lastModified: nil
        )
        try await service.createCareCircle(circle)
        let founder = FirestoreModels.FPerson(
            id: founderPersonID,
            careCircleID: circleID,
            name: "Founder",
            role: Roles.primarySupervisor,
            languagePreference: "en",
            firebaseUID: founderFirebaseUID,
            photoData: nil,
            pinHash: nil,
            pinSalt: nil,
            failedPinAttempts: 0,
            lastModified: nil
        )
        try await service.upsertPerson(founder)
        if withMembership {
            let membership = FirestoreModels.FUserMembership(
                careCircleID: circleID,
                personID: founderPersonID,
                role: Roles.primarySupervisor,
                joinedAt: Date(),
                joinCode: nil
            )
            try await service.upsertMembership(
                firebaseUID: founderFirebaseUID,
                membership: membership
            )
        }
        return (circleID, code, founderPersonID)
    }

    func test_cleanupRemovesOrphansAndKeepsRealCircle() async throws {
        guard await emulatorAvailable() else { return }
        guard let db = service.db else { return }

        let founderUID = "uid-\(UUID().uuidString)"

        let real = try await seedCircle(
            founderFirebaseUID: founderUID, withMembership: true
        )
        let orphan1 = try await seedCircle(
            founderFirebaseUID: founderUID, withMembership: false
        )
        let orphan2 = try await seedCircle(
            founderFirebaseUID: founderUID, withMembership: false
        )

        // Sanity: both orphans and the real circle are present pre-migration.
        let realPre = try await service.loadCareCircle(circleID: real.circleID)
        XCTAssertNotNil(realPre)
        let orphan1Pre = try await service.loadCareCircle(circleID: orphan1.circleID)
        XCTAssertNotNil(orphan1Pre)
        let orphan2Pre = try await service.loadCareCircle(circleID: orphan2.circleID)
        XCTAssertNotNil(orphan2Pre)

        let deleted = await OrphanCircleCleanupMigration.runIfNeeded(
            firebaseUID: founderUID, firestore: service
        )
        XCTAssertGreaterThanOrEqual(deleted, 2,
                                    "must delete the two seeded orphans")

        // Real circle untouched.
        let realPost = try await service.loadCareCircle(circleID: real.circleID)
        XCTAssertNotNil(realPost, "real circle must still exist")
        XCTAssertEqual(realPost?.joinCode, real.joinCode)

        // Real /joinCodes lookup untouched.
        let realCodeDoc = try await db
            .document("\(FirestoreService.Path.joinCodes)/\(real.joinCode)")
            .getDocument()
        XCTAssertTrue(realCodeDoc.exists,
                      "real /joinCodes lookup must remain")

        // Both orphans gone.
        let orphan1Post = try await service.loadCareCircle(circleID: orphan1.circleID)
        XCTAssertNil(orphan1Post, "orphan1 careCircle must be deleted")
        let orphan2Post = try await service.loadCareCircle(circleID: orphan2.circleID)
        XCTAssertNil(orphan2Post, "orphan2 careCircle must be deleted")

        // Orphan /joinCodes lookups gone.
        let orphan1Code = try await db
            .document("\(FirestoreService.Path.joinCodes)/\(orphan1.joinCode)")
            .getDocument()
        XCTAssertFalse(orphan1Code.exists, "orphan1 /joinCodes must be deleted")
        let orphan2Code = try await db
            .document("\(FirestoreService.Path.joinCodes)/\(orphan2.joinCode)")
            .getDocument()
        XCTAssertFalse(orphan2Code.exists, "orphan2 /joinCodes must be deleted")

        // Orphan subcollections gone (Person docs).
        let orphan1People = try await db
            .collection(FirestoreService.Path.people(orphan1.circleID))
            .getDocuments()
        XCTAssertEqual(orphan1People.documents.count, 0,
                       "orphan1 people subcollection must be empty")

        // Flag flipped — second run is a no-op.
        XCTAssertTrue(OrphanCircleCleanupMigration.isComplete)
        let secondRun = await OrphanCircleCleanupMigration.runIfNeeded(
            firebaseUID: founderUID, firestore: service
        )
        XCTAssertEqual(secondRun, 0, "migration must be idempotent")
    }

    func test_cleanupSkipsWhenUserHasNoMembership() async throws {
        guard await emulatorAvailable() else { return }

        let founderUID = "no-membership-\(UUID().uuidString)"
        // Seed an orphan but no /userMemberships for this user.
        _ = try await seedCircle(
            founderFirebaseUID: founderUID, withMembership: false
        )

        let deleted = await OrphanCircleCleanupMigration.runIfNeeded(
            firebaseUID: founderUID, firestore: service
        )
        XCTAssertEqual(deleted, 0,
                       "without /userMemberships we cannot tell orphan from real — defer")
        XCTAssertFalse(OrphanCircleCleanupMigration.isComplete,
                       "deferred run must NOT flip the flag")
    }
}
