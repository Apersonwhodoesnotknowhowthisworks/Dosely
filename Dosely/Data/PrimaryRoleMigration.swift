import CoreData
import Foundation

/// One-shot migration that splits the legacy `"supervisor"` role into
/// `"primary_supervisor"` and `"secondary_supervisor"` and stamps every
/// CareCircle with a `primarySupervisorPersonID`.
///
/// **Selection rule**: there's no `foundingSupervisorFirebaseUID` field
/// on existing CareCircle docs, so we pick the supervisor whose
/// `Person.id` UUID string sorts first as the primary. This is
/// deterministic across devices — every device that runs the migration
/// for the same circle picks the same answer, so concurrent migrations
/// from two devices converge on the same result without coordination.
///
/// **Order**: every supervisor in the circle is included in a single
/// Firestore batch. The selected primary's role becomes
/// `primary_supervisor`; everyone else becomes `secondary_supervisor`.
/// `CareCircle.primarySupervisorPersonID` and each affected
/// `/userMemberships/{uid}.role` are updated in the same batch — see
/// `FirestoreService.applyPrimaryAssignment`. The Firestore rules'
/// `isPromotionBatch` helper recognizes this exact shape.
///
/// Idempotent via `UserDefaults["primary_role_migration_v1"]`.
enum PrimaryRoleMigration {
    static let flagKey = "primary_role_migration_v1"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Runs the migration. Safe to call on every launch — gated by the
    /// UserDefaults flag, and a no-op when the local store has no
    /// CareCircles needing assignment.
    @discardableResult
    static func runIfNeeded(
        stack: CoreDataStack = .shared,
        firestore: FirestoreService = .shared
    ) async -> Bool {
        if isComplete { return false }

        let plans = await collectPlans(stack: stack)

        // Nothing to migrate (e.g. fresh install, no circles yet, or
        // every circle is already stamped). Flip the flag so we don't
        // sweep on every launch — new circles created post-migration
        // set `primarySupervisorPersonID` directly at create time.
        guard !plans.isEmpty else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return false
        }

        var anyApplied = false
        for plan in plans {
            do {
                try await firestore.applyPrimaryAssignment(
                    circleID: plan.circleID.uuidString,
                    newPrimaryPersonID: plan.primaryPersonID.uuidString,
                    supervisors: plan.supervisors.map {
                        ($0.personID.uuidString, $0.firebaseUID)
                    }
                )
                await mirrorLocally(plan: plan, stack: stack)
                anyApplied = true
            } catch FirestoreServiceError.permissionDenied {
                // Another device migrated this circle first. The
                // listener will catch up the local state; treat as a
                // success for our flag.
                anyApplied = true
            } catch {
                // Don't flip the flag — try again next launch.
                return false
            }
        }

        if anyApplied {
            UserDefaults.standard.set(true, forKey: flagKey)
        }
        return anyApplied
    }

    // MARK: - Plan

    fileprivate struct Plan {
        let circleID: UUID
        let primaryPersonID: UUID
        let supervisors: [SupervisorEntry]
    }

    fileprivate struct SupervisorEntry {
        let personID: UUID
        let firebaseUID: String?
    }

    /// Reads Core Data and produces one Plan per CareCircle that lacks
    /// a `primarySupervisorPersonID`. The lowest-UUID supervisor in the
    /// circle is picked as the primary.
    private static func collectPlans(stack: CoreDataStack) async -> [Plan] {
        let context = stack.viewContext
        return await context.perform {
            let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
            request.predicate = NSPredicate(format: "primarySupervisorPersonID == nil")
            let circles = (try? context.fetch(request)) ?? []
            return circles.compactMap { circle -> Plan? in
                guard let circleID = circle.id else { return nil }
                let people = (circle.people as? Set<Person>) ?? []
                let supervisors = people.filter { Roles.isAnySupervisor($0.role) }
                guard !supervisors.isEmpty else { return nil }
                let entries = supervisors
                    .compactMap { p -> SupervisorEntry? in
                        guard let id = p.id else { return nil }
                        return SupervisorEntry(personID: id, firebaseUID: p.firebaseUID)
                    }
                    .sorted { $0.personID.uuidString < $1.personID.uuidString }
                guard let primary = entries.first else { return nil }
                return Plan(
                    circleID: circleID,
                    primaryPersonID: primary.personID,
                    supervisors: entries
                )
            }
        }
    }

    /// Applies the plan to local Core Data. The SyncCoordinator listener
    /// will overwrite this from Firestore shortly anyway, but mirroring
    /// immediately keeps the UI in step on the migrating device.
    private static func mirrorLocally(plan: Plan, stack: CoreDataStack) async {
        let context = stack.viewContext
        await context.perform {
            let circleRequest = NSFetchRequest<CareCircle>(entityName: "CareCircle")
            circleRequest.predicate = NSPredicate(format: "id == %@", plan.circleID as CVarArg)
            circleRequest.fetchLimit = 1
            guard let circle = (try? context.fetch(circleRequest))?.first else { return }
            circle.primarySupervisorPersonID = plan.primaryPersonID

            let people = (circle.people as? Set<Person>) ?? []
            for person in people where Roles.isAnySupervisor(person.role) {
                guard let id = person.id else { continue }
                person.role = id == plan.primaryPersonID
                    ? Roles.primarySupervisor
                    : Roles.secondarySupervisor
            }
            try? context.save()
        }
    }

    /// Test helper.
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: flagKey)
    }
}
