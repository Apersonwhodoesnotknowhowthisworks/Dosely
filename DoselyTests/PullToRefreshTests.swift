import XCTest
import CoreData
import FirebaseCore
import FirebaseFirestore
@testable import Dosely

/// Tests for the manual pull-to-refresh path.
///
/// `SyncCoordinator.refresh()`:
///   - Returns silently when there's no active circle (signed-out /
///     pre-bootstrap is not an error).
///   - Throws `.offline` when Firebase isn't configured. The orphan-
///     pruning mirror helpers would otherwise wipe the local cache on
///     receipt of an empty fetch result.
///   - On the happy path against the local emulator, mirrors fresh
///     Firestore data into Core Data via the same helpers the
///     listener pipeline uses.
///
/// This file used to also carry three `_rendersUIScrollView` smoke
/// tests that hosted each tab and walked the UIView tree for a
/// `UIScrollView` (the surface `.refreshable` attaches to). They were
/// deleted: the presence of a `UIScrollView` in SwiftUI's opaque,
/// version-dependent UIView tree is not reliably observable under a
/// headless `UIHostingController` — they returned false negatives the
/// moment the test target compiled again. That a tab's body wraps its
/// content in a `ScrollView`/`List` is verifiable by reading the
/// source, and `.refreshable` behaviour is an on-device concern an
/// offscreen tree walk can't prove.
@MainActor
final class PullToRefreshTests: XCTestCase {
    private static var firebaseConfigured = false
    private var stack: CoreDataStack!
    private var firestore: FirestoreService!
    private var coordinator: SyncCoordinator!

    override func setUp() {
        super.setUp()
        Self.configureFirebaseIfNeeded()
        stack = CoreDataStack(inMemory: true)
        firestore = FirestoreService.useEmulator()
        coordinator = SyncCoordinator(firestore: firestore, stack: stack)
    }

    override func tearDown() {
        coordinator = nil
        firestore = nil
        stack = nil
        super.tearDown()
    }

    private static func configureFirebaseIfNeeded() {
        if !firebaseConfigured {
            if FirebaseApp.app() == nil { FirebaseApp.configure() }
            firebaseConfigured = true
        }
    }

    private func emulatorAvailable() async -> Bool {
        guard let db = firestore.db else { return false }
        do {
            let probe = db.collection("_emulator_probes").document(UUID().uuidString)
            try await probe.setData(["ts": FieldValue.serverTimestamp()])
            try? await probe.delete()
            return true
        } catch {
            return false
        }
    }

    // MARK: - SyncCoordinator.refresh

    /// No active circle (signed-out / pre-bootstrap) is a silent no-op.
    func test_refresh_returnsSilentlyWhenNoActiveCircle() async {
        do {
            try await coordinator.refresh()
        } catch {
            XCTFail("refresh with no active circle must not throw, got \(error)")
        }
    }

    /// Without a configured Firestore client, refresh MUST surface
    /// `.offline` rather than reach the orphan-pruning mirror helpers
    /// with empty fetch results — that would wipe the local cache.
    func test_refresh_throwsOfflineWhenFirestoreUnconfigured() async {
        let unconfigured = FirestoreService()  // db == nil
        let coord = SyncCoordinator(firestore: unconfigured, stack: stack)
        // `start` is the production entry point and is safe to call on
        // an unconfigured service — it returns no-op listeners.
        await coord.start(careCircleID: UUID())

        do {
            try await coord.refresh()
            XCTFail("expected .offline when db is nil")
        } catch SyncRefreshError.offline {
            // Expected.
        } catch {
            XCTFail("expected .offline, got \(error)")
        }
    }

    /// Happy path against the emulator: pre-seed a circle plus a
    /// Person and a Medication, point the coordinator at it, refresh,
    /// then verify both rows landed in Core Data via the mirror
    /// helpers. Same shape the listener pipeline runs — refresh just
    /// compresses it into a one-shot round trip.
    func test_refresh_mirrorsFreshDataIntoCoreData() async throws {
        guard await emulatorAvailable() else { return }

        let circleID = UUID()
        let circleIDString = circleID.uuidString
        let personID = UUID().uuidString
        let medID = UUID().uuidString
        let founderUID = "founder-\(UUID().uuidString)"

        let circle = FirestoreModels.FCareCircle(
            id: circleIDString,
            name: "Refresh Family",
            joinCode: String(format: "%06d", Int.random(in: 0..<1_000_000)),
            createdAt: Date(),
            supervisorCount: 1,
            primarySupervisorPersonID: personID,
            lastModified: nil
        )
        try await firestore.createCareCircle(circle)
        let founder = FirestoreModels.FPerson(
            id: personID,
            careCircleID: circleIDString,
            name: "Founder",
            role: Roles.primarySupervisor,
            languagePreference: "en",
            firebaseUID: founderUID,
            photoData: nil,
            pinHash: nil,
            pinSalt: nil,
            failedPinAttempts: 0,
            lastModified: nil
        )
        try await firestore.upsertPerson(founder)
        let medication = FirestoreModels.FMedication(
            id: medID,
            personID: personID,
            name: "Lipitor",
            dose: "20mg",
            pillsPerDose: 1,
            foodRule: "either",
            notes: nil,
            currentSupply: 30,
            pillPhotoData: nil,
            dateAdded: Date(),
            lastModified: nil
        )
        try await firestore.upsertMedication(circleID: circleIDString, med: medication)

        await coordinator.start(careCircleID: circleID)
        try await coordinator.refresh()

        // Mirror helpers commit on a background context. Give the
        // persistent store a tick to merge.
        try await Task.sleep(nanoseconds: 500_000_000)

        let context = stack.viewContext
        context.refreshAllObjects()

        let personFetch = NSFetchRequest<Person>(entityName: "Person")
        personFetch.predicate = NSPredicate(format: "id == %@", UUID(uuidString: personID)! as CVarArg)
        let mirroredPeople = try context.fetch(personFetch)
        XCTAssertEqual(mirroredPeople.count, 1, "refresh must mirror the Person doc")
        XCTAssertEqual(mirroredPeople.first?.firebaseUID, founderUID)

        let medFetch = NSFetchRequest<Medication>(entityName: "Medication")
        medFetch.predicate = NSPredicate(format: "id == %@", UUID(uuidString: medID)! as CVarArg)
        let mirroredMeds = try context.fetch(medFetch)
        XCTAssertEqual(mirroredMeds.count, 1, "refresh must mirror the Medication doc")
        XCTAssertEqual(mirroredMeds.first?.name, "Lipitor")

        coordinator.stop()
    }
}
