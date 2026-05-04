import CoreData
import Foundation

/// Reads alerts from Core Data (kept fresh by `SyncCoordinator`'s
/// listener), writes new alerts via `FirestoreService.createAlertIfAbsent`,
/// and runs the acknowledgement transaction. Reads stay synchronous
/// from Core Data so the dashboard renders instantly; writes go to
/// Firestore first and the listener mirrors them back.
///
/// Sort: pending alerts (acknowledgedBy == nil) first, then
/// acknowledged, both ordered by `createdAt` descending. The dashboard
/// reads `pending` and `acknowledged` separately when it wants either
/// half explicitly.
final class AlertsRepository {
    private let stack: CoreDataStack
    private let firestore: FirestoreService

    init(stack: CoreDataStack = .shared,
         firestore: FirestoreService = .shared) {
        self.stack = stack
        self.firestore = firestore
    }

    private var context: NSManagedObjectContext { stack.viewContext }

    // MARK: - Reads (Core Data, synchronous)

    /// All alerts for the circle, sorted: pending first, then
    /// acknowledged, both descending by `createdAt`.
    func fetchAlerts(in careCircleID: UUID) async -> [Alert] {
        await context.perform { [context] in
            let request = NSFetchRequest<Alert>(entityName: "Alert")
            request.predicate = NSPredicate(format: "careCircle.id == %@", careCircleID as CVarArg)
            let all = (try? context.fetch(request)) ?? []
            return all.sorted { lhs, rhs in
                let lPending = (lhs.acknowledgedByFirebaseUID ?? "").isEmpty
                let rPending = (rhs.acknowledgedByFirebaseUID ?? "").isEmpty
                if lPending != rPending { return lPending }
                let lDate = lhs.createdAt ?? .distantPast
                let rDate = rhs.createdAt ?? .distantPast
                return lDate > rDate
            }
        }
    }

    /// Alerts whose `acknowledgedByFirebaseUID` is nil. Convenience
    /// for the AlertsCard's "needs attention" list.
    func fetchPending(in careCircleID: UUID) async -> [Alert] {
        await fetchAlerts(in: careCircleID).filter {
            ($0.acknowledgedByFirebaseUID ?? "").isEmpty
        }
    }

    // MARK: - Writes

    /// Idempotent create. Returns true if this call wrote the doc,
    /// false if a sibling supervisor's device beat it. Either way the
    /// alert is in the system once this returns; callers can ignore
    /// the result for the common case.
    @discardableResult
    func createIfAbsent(_ alert: FirestoreModels.FAlert,
                        in careCircleID: UUID) async throws -> Bool {
        let landed = try await firestore.createAlertIfAbsent(
            circleID: careCircleID.uuidString,
            alert: alert
        )
        // Mirror locally on success so the UI updates without waiting
        // on the listener round trip. The listener's snapshot will
        // reconcile any drift (e.g. server timestamp on createdAt).
        if landed {
            await context.perform { [context] in
                alert.upsert(in: context, careCircleID: careCircleID)
                try? context.save()
            }
        }
        return landed
    }

    /// Atomic acknowledgement. Silently returns if someone else
    /// already ack'd (the listener will deliver the new state).
    /// Throws `.offline` / `.permissionDenied` for the caller to map.
    func acknowledge(alertID: String,
                     in careCircleID: UUID,
                     firebaseUID: String,
                     actorName: String?) async throws {
        try await firestore.acknowledgeAlert(
            circleID: careCircleID.uuidString,
            alertID: alertID,
            firebaseUID: firebaseUID,
            actorName: actorName
        )
        // Optimistically mirror locally — the listener will overwrite
        // with the server timestamp shortly. If the server-side write
        // turned into a no-op (race lost), the listener will correct
        // us on the next snapshot.
        await context.perform { [context] in
            let request = NSFetchRequest<Alert>(entityName: "Alert")
            request.predicate = NSPredicate(format: "docID == %@", alertID)
            request.fetchLimit = 1
            guard let alert = (try? context.fetch(request))?.first,
                  (alert.acknowledgedByFirebaseUID ?? "").isEmpty else { return }
            alert.acknowledgedByFirebaseUID = firebaseUID
            alert.acknowledgedByName = actorName
            alert.acknowledgedAt = Date()
            try? context.save()
        }
    }
}
