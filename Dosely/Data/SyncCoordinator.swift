import CoreData
import FirebaseFirestore
import Foundation

/// Owns the Firestore listeners that keep Core Data in sync with the
/// active care circle. Reads remain synchronous from Core Data; writes
/// go through the repositories. SyncCoordinator's job is purely the
/// inbound side — Firestore → Core Data.
///
/// Lifecycle: AuthService starts the coordinator after a CareCircle
/// resolves (sign-in, circle creation, circle join), and stops it on
/// sign-out / leave-and-join. A circle change re-targets all listeners.
@MainActor
final class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()

    private let firestore: FirestoreService
    private let stack: CoreDataStack

    private(set) var activeCircleID: UUID?
    private var listeners: [ListenerRegistration] = []

    init(firestore: FirestoreService = .shared, stack: CoreDataStack = .shared) {
        self.firestore = firestore
        self.stack = stack
    }

    // MARK: - Lifecycle

    /// Starts (or re-targets) listeners for `careCircleID`. Idempotent:
    /// calling with the currently-active id is a no-op; calling with a
    /// new id tears down old listeners first.
    func start(careCircleID: UUID) async {
        if activeCircleID == careCircleID, !listeners.isEmpty { return }
        stop()
        activeCircleID = careCircleID
        let id = careCircleID.uuidString

        listeners.append(firestore.listenDocument(
            documentPath: FirestoreService.Path.careCircle(id),
            as: FirestoreModels.FCareCircle.self
        ) { [weak self] circle in
            guard let self, let circle else { return }
            self.mirrorCircle(circle)
        })

        listeners.append(firestore.listen(
            collectionPath: FirestoreService.Path.people(id),
            as: FirestoreModels.FPerson.self
        ) { [weak self] people in
            guard let self else { return }
            self.mirrorPeople(people, circleID: careCircleID)
        })

        listeners.append(firestore.listen(
            collectionPath: FirestoreService.Path.medications(id),
            as: FirestoreModels.FMedication.self
        ) { [weak self] meds in
            guard let self else { return }
            self.mirrorMedications(meds, circleID: careCircleID)
        })

        listeners.append(firestore.listen(
            collectionPath: FirestoreService.Path.doseSchedules(id),
            as: FirestoreModels.FDoseSchedule.self
        ) { [weak self] schedules in
            guard let self else { return }
            self.mirrorSchedules(schedules, circleID: careCircleID)
        })

        listeners.append(firestore.listen(
            collectionPath: FirestoreService.Path.doseLogs(id),
            as: FirestoreModels.FDoseLog.self
        ) { [weak self] logs in
            guard let self else { return }
            self.mirrorDoseLogs(logs, circleID: careCircleID)
        })
    }

    func stop() {
        for listener in listeners { listener.remove() }
        listeners.removeAll()
        activeCircleID = nil
    }

    // MARK: - Mirror helpers (Firestore → Core Data)

    private func mirrorCircle(_ circle: FirestoreModels.FCareCircle) {
        stack.performBackgroundTask { ctx in
            circle.upsert(in: ctx)
            try? ctx.save()
        }
    }

    private func mirrorPeople(_ people: [FirestoreModels.FPerson], circleID: UUID) {
        stack.performBackgroundTask { ctx in
            for person in people { person.upsert(in: ctx) }
            Self.deleteOrphaned(
                entityName: "Person",
                keepIDs: people.compactMap { UUID(uuidString: $0.id) },
                in: ctx,
                scopedTo: circleID,
                scopedKey: "careCircle.id"
            )
            try? ctx.save()
        }
    }

    private func mirrorMedications(_ meds: [FirestoreModels.FMedication], circleID: UUID) {
        stack.performBackgroundTask { ctx in
            for med in meds { med.upsert(in: ctx) }
            // Medications are scoped by personID, but every Person on
            // the device that belongs to this circle is represented in
            // Firestore — so a med whose id isn't in the Firestore list
            // *and* whose personID belongs to this circle is gone.
            let circlePeopleIDs = Self.peopleIDs(in: circleID, ctx: ctx)
            Self.deleteOrphanedMedications(
                keepIDs: meds.compactMap { UUID(uuidString: $0.id) },
                personIDs: circlePeopleIDs,
                in: ctx
            )
            try? ctx.save()
        }
    }

    private func mirrorSchedules(_ schedules: [FirestoreModels.FDoseSchedule], circleID: UUID) {
        stack.performBackgroundTask { ctx in
            for schedule in schedules { schedule.upsert(in: ctx) }
            let circlePeopleIDs = Self.peopleIDs(in: circleID, ctx: ctx)
            Self.deleteOrphanedSchedules(
                keepIDs: schedules.compactMap { UUID(uuidString: $0.id) },
                personIDs: circlePeopleIDs,
                in: ctx
            )
            try? ctx.save()
        }
    }

    private func mirrorDoseLogs(_ logs: [FirestoreModels.FDoseLog], circleID: UUID) {
        stack.performBackgroundTask { ctx in
            for log in logs { log.upsert(in: ctx) }
            let circlePeopleIDs = Self.peopleIDs(in: circleID, ctx: ctx)
            Self.deleteOrphanedDoseLogs(
                keepIDs: logs.compactMap { UUID(uuidString: $0.id) },
                personIDs: circlePeopleIDs,
                in: ctx
            )
            try? ctx.save()
        }
    }

    // MARK: - Reconciliation helpers

    /// Generic delete-orphans for entities scoped by a CareCircle key
    /// path (e.g. Person → careCircle.id).
    private static func deleteOrphaned(
        entityName: String,
        keepIDs: [UUID],
        in ctx: NSManagedObjectContext,
        scopedTo circleID: UUID,
        scopedKey: String
    ) {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "%K == %@", scopedKey, circleID as CVarArg)
        let existing = (try? ctx.fetch(request)) ?? []
        let keepSet = Set(keepIDs)
        for obj in existing {
            guard let id = obj.value(forKey: "id") as? UUID else { continue }
            if !keepSet.contains(id) { ctx.delete(obj) }
        }
    }

    private static func peopleIDs(in circleID: UUID, ctx: NSManagedObjectContext) -> Set<UUID> {
        let request = NSFetchRequest<Person>(entityName: "Person")
        request.predicate = NSPredicate(format: "careCircle.id == %@", circleID as CVarArg)
        let people = (try? ctx.fetch(request)) ?? []
        return Set(people.compactMap { $0.id })
    }

    private static func deleteOrphanedMedications(
        keepIDs: [UUID],
        personIDs: Set<UUID>,
        in ctx: NSManagedObjectContext
    ) {
        let request = NSFetchRequest<Medication>(entityName: "Medication")
        let existing = (try? ctx.fetch(request)) ?? []
        let keepSet = Set(keepIDs)
        for med in existing {
            guard let medID = med.id, let personID = med.personID,
                  personIDs.contains(personID) else { continue }
            if !keepSet.contains(medID) { ctx.delete(med) }
        }
    }

    private static func deleteOrphanedSchedules(
        keepIDs: [UUID],
        personIDs: Set<UUID>,
        in ctx: NSManagedObjectContext
    ) {
        let request = NSFetchRequest<DoseSchedule>(entityName: "DoseSchedule")
        let existing = (try? ctx.fetch(request)) ?? []
        let keepSet = Set(keepIDs)
        for schedule in existing {
            guard let id = schedule.id,
                  let personID = schedule.medication?.personID,
                  personIDs.contains(personID) else { continue }
            if !keepSet.contains(id) { ctx.delete(schedule) }
        }
    }

    private static func deleteOrphanedDoseLogs(
        keepIDs: [UUID],
        personIDs: Set<UUID>,
        in ctx: NSManagedObjectContext
    ) {
        let request = NSFetchRequest<DoseLog>(entityName: "DoseLog")
        let existing = (try? ctx.fetch(request)) ?? []
        let keepSet = Set(keepIDs)
        for log in existing {
            guard let id = log.id,
                  let personID = log.medication?.personID,
                  personIDs.contains(personID) else { continue }
            if !keepSet.contains(id) { ctx.delete(log) }
        }
    }
}
