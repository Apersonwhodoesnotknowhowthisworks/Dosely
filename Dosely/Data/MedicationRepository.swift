import CoreData
import Foundation

struct ScheduleInput: Equatable {
    var id: UUID
    var timeOfDay: String
    var daysOfWeek: Int16

    init(id: UUID = UUID(), timeOfDay: String, daysOfWeek: Int16 = 127) {
        self.id = id
        self.timeOfDay = timeOfDay
        self.daysOfWeek = daysOfWeek
    }
}

// Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32, Sun=64. 127 = every day.
enum WeekdayBitmask {
    static func mask(for date: Date, calendar: Calendar = .current) -> Int16 {
        let weekday = calendar.component(.weekday, from: date)
        switch weekday {
        case 1: return 64
        case 2: return 1
        case 3: return 2
        case 4: return 4
        case 5: return 8
        case 6: return 16
        case 7: return 32
        default: return 0
        }
    }
}

enum MedicationRepositoryError: Error, Equatable {
    case actorNotFound
    case permissionDenied
    case medicationNotFound
}

/// Medication reads are local-only (Core Data, instant). Writes hit
/// Firestore first; on success we mirror to Core Data. Schedules are
/// stored as a flat subcollection under the care circle (not nested
/// under medication) so the SyncCoordinator can listen to them with one
/// Firestore call regardless of how many medications exist.
final class MedicationRepository {
    private let stack: CoreDataStack
    private let firestore: FirestoreService

    init(stack: CoreDataStack = .shared, firestore: FirestoreService = .shared) {
        self.stack = stack
        self.firestore = firestore
    }

    private var context: NSManagedObjectContext { stack.viewContext }

    // MARK: - Reads

    func fetchAllMedications(for personID: UUID) async -> [Medication] {
        await context.perform { [context] in
            let request = NSFetchRequest<Medication>(entityName: "Medication")
            request.predicate = NSPredicate(format: "personID == %@", personID as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: true)]
            return (try? context.fetch(request)) ?? []
        }
    }

    func fetchMedication(id: UUID) async -> Medication? {
        await context.perform { [context] in
            Self.find(id: id, in: context)
        }
    }

    func fetchScheduledDoses(for personID: UUID, on date: Date) async -> [(Medication, DoseSchedule)] {
        await context.perform { [context] in
            let mask = WeekdayBitmask.mask(for: date)
            let request = NSFetchRequest<DoseSchedule>(entityName: "DoseSchedule")
            request.predicate = NSPredicate(format: "medication.personID == %@", personID as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "timeOfDay", ascending: true)]
            let all = (try? context.fetch(request)) ?? []
            return all.compactMap { schedule in
                guard (schedule.daysOfWeek & mask) != 0, let med = schedule.medication else { return nil }
                return (med, schedule)
            }
        }
    }

    func fetchDoseLogs(
        for medicationID: UUID?,
        personID: UUID,
        from: Date,
        to: Date
    ) async -> [DoseLog] {
        await context.perform { [context] in
            let request = NSFetchRequest<DoseLog>(entityName: "DoseLog")
            var predicates: [NSPredicate] = [
                NSPredicate(format: "scheduledTime >= %@ AND scheduledTime <= %@",
                            from as NSDate, to as NSDate),
                NSPredicate(format: "medication.personID == %@", personID as CVarArg)
            ]
            if let medicationID {
                predicates.append(NSPredicate(format: "medication.id == %@", medicationID as CVarArg))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "scheduledTime", ascending: true)]
            return (try? context.fetch(request)) ?? []
        }
    }

    // MARK: - Writes

    @discardableResult
    func saveMedication(
        personID: UUID,
        actorPersonID: UUID,
        id: UUID? = nil,
        name: String,
        dose: String,
        pillsPerDose: Int16,
        foodRule: String,
        notes: String?,
        currentSupply: Int16,
        pillPhotoData: Data?,
        schedules: [ScheduleInput] = []
    ) async throws -> Medication {
        struct WritePayload {
            let medID: UUID
            let circleID: UUID
            let fmed: FirestoreModels.FMedication
            let fschedules: [FirestoreModels.FDoseSchedule]
        }

        let (med, payload): (Medication, WritePayload) = try await context.perform { [context] in
            guard let actor = Self.findPerson(id: actorPersonID, in: context) else {
                throw MedicationRepositoryError.actorNotFound
            }
            guard let circle = actor.careCircle, let circleID = circle.id else {
                throw MedicationRepositoryError.actorNotFound
            }
            guard Self.isPrimary(actor: actor, circle: circle) else {
                throw MedicationRepositoryError.permissionDenied
            }

            let med: Medication
            if let id, let existing = Self.find(id: id, in: context) {
                med = existing
            } else {
                med = Medication(context: context)
                med.id = id ?? UUID()
                med.dateAdded = Date()
            }
            med.personID = personID
            med.name = name
            med.dose = dose
            med.pillsPerDose = pillsPerDose
            med.foodRule = foodRule
            med.notes = notes
            med.currentSupply = currentSupply
            med.pillPhotoData = pillPhotoData

            Self.replaceSchedules(on: med, with: schedules, in: context)
            try? context.save()

            guard let medID = med.id else {
                throw MedicationRepositoryError.medicationNotFound
            }
            let fmed = FirestoreModels.FMedication(from: med)
            let fschedules: [FirestoreModels.FDoseSchedule] = schedules.map { input in
                FirestoreModels.FDoseSchedule(
                    id: input.id.uuidString,
                    medicationID: medID.uuidString,
                    timeOfDay: input.timeOfDay,
                    daysOfWeek: Int(input.daysOfWeek),
                    lastModified: nil
                )
            }
            let payload = WritePayload(
                medID: medID, circleID: circleID,
                fmed: fmed, fschedules: fschedules
            )
            return (med, payload)
        }

        try? await firestore.upsertMedication(circleID: payload.circleID.uuidString, med: payload.fmed)
        try? await firestore.replaceSchedules(
            circleID: payload.circleID.uuidString,
            medicationID: payload.medID.uuidString,
            schedules: payload.fschedules
        )
        return med
    }

    func deleteMedication(id: UUID, actorPersonID: UUID) async throws {
        struct DeletePayload {
            let medID: UUID
            let circleID: UUID
        }

        let prepared: DeletePayload? = try await context.perform { [context] in
            guard let actor = Self.findPerson(id: actorPersonID, in: context) else {
                throw MedicationRepositoryError.actorNotFound
            }
            guard let circle = actor.careCircle, let circleID = circle.id else {
                throw MedicationRepositoryError.actorNotFound
            }
            guard Self.isPrimary(actor: actor, circle: circle) else {
                throw MedicationRepositoryError.permissionDenied
            }
            guard let med = Self.find(id: id, in: context) else { return nil }
            guard let medID = med.id else {
                return nil
            }
            context.delete(med)
            try? context.save()
            return DeletePayload(medID: medID, circleID: circleID)
        }

        guard let prepared else { return }
        try? await firestore.deleteMedication(
            circleID: prepared.circleID.uuidString,
            medicationID: prepared.medID.uuidString
        )
    }

    @discardableResult
    func logDose(
        medicationID: UUID,
        scheduledTime: Date,
        actualTime: Date?,
        status: String,
        loggedByPersonID: UUID
    ) async -> DoseLog? {
        struct LogPayload {
            let circleID: UUID
            let flog: FirestoreModels.FDoseLog
            let supplyChange: (medicationID: String, delta: Int)?
        }

        let prepared: (DoseLog, LogPayload)? = await context.perform { [context] in
            guard let med = Self.find(id: medicationID, in: context) else { return nil }
            // Resolve the care circle through the Person who owns the
            // medication, since DoseLogs aren't directly attached to a
            // circle in Core Data.
            guard let personID = med.personID,
                  let person = Self.findPerson(id: personID, in: context),
                  let circleID = person.careCircle?.id else { return nil }

            // Secondary supervisors cannot log doses (read-only mode).
            // Device clients logging their own dose, or the primary
            // supervisor logging on someone's behalf, are both fine.
            if let actor = Self.findPerson(id: loggedByPersonID, in: context),
               actor.role == Roles.secondarySupervisor {
                return nil
            }

            // Supply delta from the state TRANSITION for this scheduled time,
            // not the new status alone. A "taken" log consumes one unit; if a
            // prior "taken" already consumed it (a re-tap, or a notification +
            // in-app double-log) the delta is 0; correcting away from taken
            // restores one. Computed before inserting the new log so the new
            // row doesn't count as its own "prior".
            let priorTaken = Self.hasTakenLog(
                medicationID: medicationID, scheduledTime: scheduledTime, in: context
            )
            let consumedBefore = priorTaken ? 1 : 0
            let consumedAfter = (status == DoseStatus.taken.rawValue) ? 1 : 0
            var supplyDelta = consumedBefore - consumedAfter   // -1 take, +1 restore, 0 none
            // Floor at 0: never decrement below the locally-known supply. No
            // upward cap on a restore — the user may have refilled in between.
            if supplyDelta < 0 && med.currentSupply <= 0 { supplyDelta = 0 }
            if supplyDelta != 0 {
                med.currentSupply = Int16(max(0, Int(med.currentSupply) + supplyDelta))
            }

            let log = DoseLog(context: context)
            log.id = UUID()
            log.scheduledTime = scheduledTime
            log.actualTime = actualTime
            log.status = status
            log.loggedByPersonID = loggedByPersonID
            log.medication = med
            try? context.save()

            let flog = FirestoreModels.FDoseLog(from: log)
            let supplyChange: (medicationID: String, delta: Int)? =
                supplyDelta != 0 ? (medicationID.uuidString, supplyDelta) : nil
            return (log, LogPayload(circleID: circleID, flog: flog, supplyChange: supplyChange))
        }

        guard let prepared else { return nil }
        let (log, payload) = prepared
        // The supply change rides in the SAME batch as the dose log so the two
        // never diverge (Firestore-first; both commit or neither). `try?` keeps
        // the existing offline-first contract: the SDK queues the batch and
        // replays it on reconnect, so a logged dose surfaces locally at once.
        try? await firestore.upsertDoseLog(
            circleID: payload.circleID.uuidString,
            log: payload.flog,
            supplyChange: payload.supplyChange
        )
        return log
    }

    /// Whether a `taken` dose log already exists for this medication at this
    /// scheduled time (within a minute, matching the detectors' tolerance).
    /// Lets `logDose` derive the supply delta from the transition so a re-tap
    /// never double-decrements and a correction restores exactly once.
    private static func hasTakenLog(
        medicationID: UUID, scheduledTime: Date, in context: NSManagedObjectContext
    ) -> Bool {
        let request = NSFetchRequest<DoseLog>(entityName: "DoseLog")
        request.predicate = NSPredicate(
            format: "medication.id == %@ AND status == %@",
            medicationID as CVarArg, DoseStatus.taken.rawValue
        )
        let logs = (try? context.fetch(request)) ?? []
        return logs.contains { log in
            guard let t = log.scheduledTime else { return false }
            return abs(t.timeIntervalSince(scheduledTime)) < 60
        }
    }

    // MARK: - Helpers

    private static func find(id: UUID, in context: NSManagedObjectContext) -> Medication? {
        let request = NSFetchRequest<Medication>(entityName: "Medication")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func findPerson(id: UUID, in context: NSManagedObjectContext) -> Person? {
        let request = NSFetchRequest<Person>(entityName: "Person")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// True iff `actor` is the primary supervisor of `circle`. Mirrors
    /// `PersonRepository.isPrimary` but synchronous so callers already
    /// holding the Core Data context don't need a re-entrant `perform`.
    /// Pre-`PrimaryRoleMigration` circles fall back to "is the legacy
    /// supervisor" — same fallback as `PersonRepository.isPrimary`.
    private static func isPrimary(actor: Person, circle: CareCircle) -> Bool {
        if let primaryID = circle.primarySupervisorPersonID {
            return primaryID == actor.id
        }
        return Roles.isPrimarySupervisor(actor.role)
    }

    private static func replaceSchedules(
        on med: Medication,
        with inputs: [ScheduleInput],
        in context: NSManagedObjectContext
    ) {
        if let existing = med.schedules as? Set<DoseSchedule> {
            for s in existing { context.delete(s) }
        }
        for input in inputs {
            let schedule = DoseSchedule(context: context)
            schedule.id = input.id
            schedule.timeOfDay = input.timeOfDay
            schedule.daysOfWeek = input.daysOfWeek
            schedule.medication = med
        }
    }
}
