import CoreData
import FirebaseCore
import FirebaseFirestore
import XCTest
@testable import Dosely

/// Verifies that `RemotePersonResolver` lets a returning user sign in
/// with an empty Core Data cache. The bug it guards against: after a
/// sign-out (or on a second device), `CareCircleMigration` would query
/// only Core Data, find nothing, and route the user to `CircleSetupView`
/// even though their `/userMemberships` doc was sitting in Firestore the
/// whole time. The integration test seeds Firestore with the membership
/// + circle + Person, wipes Core Data, and asserts the resolver hydrates
/// from the membership index.
final class RemotePersonResolverTests: XCTestCase {

    private static var firebaseConfigured = false
    private var stack: CoreDataStack!

    override func setUp() {
        super.setUp()
        Self.configureFirebaseIfNeeded()
        stack = CoreDataStack(inMemory: true)
    }

    override func tearDown() {
        stack = nil
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

    /// Probe matches `FirestoreServiceTests.emulatorAvailable` —
    /// log-and-skip when the emulator isn't reachable so CI without
    /// the emulator doesn't break the suite.
    private func emulatorAvailable(_ service: FirestoreService) async -> Bool {
        guard let db = service.db else {
            print("[EMULATOR-SKIP] FirestoreService not configured")
            return false
        }
        do {
            let docRef = db.collection("_emulator_probes").document(UUID().uuidString)
            try await docRef.setData(["ts": FieldValue.serverTimestamp()])
            try? await docRef.delete()
            return true
        } catch {
            print("[EMULATOR-SKIP] Firestore emulator unreachable: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - .unavailable when no Firestore is configured

    /// With a no-op `FirestoreService` (no Firebase app), the resolver
    /// must short-circuit to `.unavailable` so `AuthService` falls back
    /// to local Core Data resolution rather than misclassifying the
    /// user as brand-new.
    func test_resolve_returnsUnavailable_whenFirestoreNotConfigured() async {
        let noFirestore = FirestoreService()
        let outcome = await RemotePersonResolver.resolve(
            firebaseUID: "any-uid",
            stack: stack,
            firestore: noFirestore
        )
        switch outcome {
        case .unavailable: break
        default: XCTFail("Expected .unavailable, got \(outcome)")
        }
    }

    // MARK: - End-to-end: hydrates from membership index

    /// Seed Firestore with a CareCircle + Person + /userMemberships
    /// pointing at a Firebase UID. Sign in with that UID against an
    /// empty local Core Data store. The resolver must return
    /// `.found(person)`, mirror both rows into Core Data, and the
    /// returned Person must carry the seeded firebaseUID.
    func test_resolve_hydratesFromFirestore_whenCoreDataIsEmpty() async throws {
        let service = FirestoreService.useEmulator()
        guard await emulatorAvailable(service) else { return }

        // Pre-seed Firestore — directly through the SDK so the test
        // doesn't depend on any of the production write paths.
        let firebaseUID = "test-uid-\(UUID().uuidString)"
        let circleID = UUID().uuidString
        let personID = UUID().uuidString
        let joinCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
        guard let db = service.db else {
            XCTFail("Firestore client missing after probe succeeded")
            return
        }

        try await db.document("careCircles/\(circleID)").setData([
            "id": circleID,
            "name": "Pre-seeded Family",
            "joinCode": joinCode,
            "createdAt": Date(),
            "supervisorCount": 1,
            "primarySupervisorPersonID": personID,
            "lastModified": FieldValue.serverTimestamp()
        ])
        try await db.document("joinCodes/\(joinCode)").setData([
            "careCircleID": circleID,
            "regeneratedAt": Date()
        ])
        try await db
            .collection("careCircles/\(circleID)/people")
            .document(personID)
            .setData([
                "id": personID,
                "careCircleID": circleID,
                "name": "Aunt 1",
                "role": "primary_supervisor",
                "languagePreference": "en",
                "firebaseUID": firebaseUID,
                "failedPinAttempts": 0,
                "lastModified": FieldValue.serverTimestamp()
            ])
        try await db.document("userMemberships/\(firebaseUID)").setData([
            "careCircleID": circleID,
            "personID": personID,
            "role": "primary_supervisor",
            "joinedAt": Date()
        ])

        // Sanity-check: Core Data is empty before the resolver runs.
        let preCount: Int = await stack.viewContext.perform { [stack] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            return ((try? stack?.viewContext.fetch(request)) ?? []).count
        }
        XCTAssertEqual(preCount, 0, "Core Data must start empty for this test")

        // Run the resolver.
        let outcome = await RemotePersonResolver.resolve(
            firebaseUID: firebaseUID,
            stack: stack,
            firestore: service
        )

        switch outcome {
        case .found(let person):
            XCTAssertEqual(person.firebaseUID, firebaseUID)
            XCTAssertEqual(person.role, "primary_supervisor")
            XCTAssertEqual(person.id?.uuidString, personID)
            XCTAssertEqual(person.careCircle?.id?.uuidString, circleID)
            XCTAssertEqual(person.careCircle?.name, "Pre-seeded Family")
        default:
            XCTFail("Expected .found, got \(outcome)")
        }

        // Core Data was hydrated as a side effect.
        let postCount: Int = await stack.viewContext.perform { [stack] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            return ((try? stack?.viewContext.fetch(request)) ?? []).count
        }
        XCTAssertEqual(postCount, 1, "the resolver should mirror the Person into Core Data")
    }

    // MARK: - .notFound for genuinely new accounts

    /// A Firebase UID that has never created or joined a circle has no
    /// `/userMemberships` doc. The resolver must return `.notFound` so
    /// `AuthService` routes the user to `CircleSetupView`. This is the
    /// behaviour we must NOT regress when adding the membership-first
    /// hydration.
    func test_resolve_returnsNotFound_forBrandNewFirebaseUID() async throws {
        let service = FirestoreService.useEmulator()
        guard await emulatorAvailable(service) else { return }

        let outcome = await RemotePersonResolver.resolve(
            firebaseUID: "brand-new-\(UUID().uuidString)",
            stack: stack,
            firestore: service
        )
        switch outcome {
        case .notFound: break
        default: XCTFail("Expected .notFound, got \(outcome)")
        }
    }
}
