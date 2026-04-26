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
        // Calendar.weekday: 1=Sunday ... 7=Saturday.
        let weekday = calendar.component(.weekday, from: date)
        switch weekday {
        case 1: return 64   // Sun
        case 2: return 1    // Mon
        case 3: return 2    // Tue
        case 4: return 4    // Wed
        case 5: return 8    // Thu
        case 6: return 16   // Fri
        case 7: return 32   // Sat
        default: return 0
        }
    }
}

enum MedicationRepositoryError: Error, Equatable {
    case actorNotFound
    case permissionDenied
    case medicationNotFound
}

final class MedicationRepository {
    private let stack: CoreDataStack

    init(stack: CoreDataStack = .shared) {
        self.stack = stack
    }

    private var context: NSManagedObjectContext { stack.viewContext }

    // MARK: - Reads (scoped to one Person)

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

    /// Creates or updates a Medication for `personID`. The acting caller
    /// (`actorPersonID`) must be a supervisor; clients raise
    /// `permissionDenied`. Throws are intentionally surfaced — call sites
    /// in views catch them and present a friendly banner.
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
        try await context.perform { [context] in
            guard let actor = Self.findPerson(id: actorPersonID, in: context) else {
                throw MedicationRepositoryError.actorNotFound
            }
            guard actor.role == "supervisor" else {
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
            return med
        }
    }

    func deleteMedication(id: UUID, actorPersonID: UUID) async throws {
        try await context.perform { [context] in
            guard let actor = Self.findPerson(id: actorPersonID, in: context) else {
                throw MedicationRepositoryError.actorNotFound
            }
            guard actor.role == "supervisor" else {
                throw MedicationRepositoryError.permissionDenied
            }
            guard let med = Self.find(id: id, in: context) else { return }
            context.delete(med)
            try? context.save()
        }
    }

    /// Logs a dose. `loggedByPersonID` records who marked it taken — a
    /// supervisor logging on behalf of grandma vs. grandpa logging his own.
    /// Both supervisors and device clients may log doses.
    @discardableResult
    func logDose(
        medicationID: UUID,
        scheduledTime: Date,
        actualTime: Date?,
        status: String,
        loggedByPersonID: UUID
    ) async -> DoseLog? {
        await context.perform { [context] in
            guard let med = Self.find(id: medicationID, in: context) else { return nil }
            let log = DoseLog(context: context)
            log.id = UUID()
            log.scheduledTime = scheduledTime
            log.actualTime = actualTime
            log.status = status
            log.loggedByPersonID = loggedByPersonID
            log.medication = med
            try? context.save()
            return log
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
