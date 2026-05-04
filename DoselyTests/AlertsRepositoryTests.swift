import CoreData
import XCTest
@testable import Dosely

/// Tests for `AlertsRepository`'s read sort, pending filter, and
/// optimistic local ack. The Firestore-side write paths
/// (`createIfAbsent`, `acknowledge`) hit the no-op service in this
/// suite — `.offline` is the throw — so those branches are exercised
/// against the emulator in `FirestoreServiceTests` separately. What
/// matters here is the local-cache contract.
final class AlertsRepositoryTests: XCTestCase {
    var stack: CoreDataStack!
    var repo: AlertsRepository!
    var careCircleRepo: CareCircleRepository!
    var circle: CareCircle!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        let noFirestore = FirestoreService()
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        repo = AlertsRepository(stack: stack, firestore: noFirestore)
        circle = await careCircleRepo.createCareCircle(
            name: "T", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
    }

    override func tearDown() {
        stack = nil; repo = nil; careCircleRepo = nil; circle = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func seedAlert(docID: String,
                           type: String = "missedDose",
                           personID: UUID = UUID(),
                           createdAt: Date,
                           ackUID: String? = nil,
                           ackName: String? = nil) async -> Alert {
        await stack.viewContext.perform { [self] in
            let alert = Alert(context: stack.viewContext)
            alert.docID = docID
            alert.type = type
            alert.personID = personID
            alert.createdAt = createdAt
            alert.acknowledgedByFirebaseUID = ackUID
            alert.acknowledgedByName = ackName
            alert.acknowledgedAt = ackUID == nil ? nil : createdAt
            alert.careCircle = circle
            try? stack.viewContext.save()
            return alert
        }
    }

    // MARK: - Read sort

    /// Pending alerts surface above acknowledged. Within each group,
    /// newest first.
    func testFetchAlertsSortsPendingBeforeAcknowledged() async throws {
        let now = Date()
        await seedAlert(docID: "old-pending",
                        createdAt: now.addingTimeInterval(-3600),
                        ackUID: nil)
        await seedAlert(docID: "old-acked",
                        createdAt: now.addingTimeInterval(-7200),
                        ackUID: "uid-x", ackName: "X")
        await seedAlert(docID: "new-acked",
                        createdAt: now.addingTimeInterval(-300),
                        ackUID: "uid-y", ackName: "Y")
        await seedAlert(docID: "new-pending",
                        createdAt: now,
                        ackUID: nil)

        let result = await repo.fetchAlerts(in: circle.id!)
        let order = result.compactMap { $0.docID }
        XCTAssertEqual(order, ["new-pending", "old-pending", "new-acked", "old-acked"])
    }

    func testFetchPendingExcludesAcknowledgedAlerts() async throws {
        let now = Date()
        await seedAlert(docID: "p1", createdAt: now)
        await seedAlert(docID: "p2", createdAt: now.addingTimeInterval(-60))
        await seedAlert(docID: "ack1", createdAt: now,
                        ackUID: "uid-x", ackName: "X")

        let pending = await repo.fetchPending(in: circle.id!)
        XCTAssertEqual(pending.compactMap { $0.docID }, ["p1", "p2"])
    }

    // MARK: - Optimistic ack

    /// Without Firestore, `acknowledge` throws .offline before the
    /// optimistic-local update runs — the local row stays pending.
    /// That's the right behavior: we never claim an ack landed on the
    /// server when it didn't.
    func testAcknowledgeThrowsOfflineAndLeavesLocalRowPendingWhenFirestoreMissing() async throws {
        let now = Date()
        await seedAlert(docID: "needs-ack", createdAt: now, ackUID: nil)

        do {
            try await repo.acknowledge(
                alertID: "needs-ack",
                in: circle.id!,
                firebaseUID: "uid-self",
                actorName: "Self"
            )
            XCTFail("expected .offline without a configured Firestore client")
        } catch FirestoreServiceError.offline {
            // expected
        } catch {
            XCTFail("expected .offline, got \(error)")
        }

        let pending = await repo.fetchPending(in: circle.id!)
        XCTAssertEqual(pending.compactMap { $0.docID }, ["needs-ack"],
                       "failed remote ack must not flip the local row")
    }
}
