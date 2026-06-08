import CoreData
import Foundation

/// Scans Core Data for scheduled doses whose time has come and gone
/// without a matching DoseLog, and writes a missedDose alert to
/// Firestore for each one. Idempotent via deterministic alert ids:
/// every supervisor's device runs the detector independently and they
/// all converge on the same doc — only the first write commits, the
/// rest get a benign "already exists" back from
/// `AlertsRepository.createIfAbsent`.
///
/// Cadence: TodayView and SupervisorDashboardView call this on
/// foreground / pull-to-refresh / the existing 5-minute timer that
/// already kicks `MissedDoseChecker` (which marks DoseLogs missed).
/// The alert generator runs after the local checker so every dose
/// already has its terminal status before we look for gaps.
final class MissedDoseDetector {
    /// Doses that are this fresh past their scheduled time aren't
    /// considered missed yet — accommodates someone who's mid-tap.
    static let defaultGraceWindow: TimeInterval = 30 * 60   // 30 minutes

    private let stack: CoreDataStack
    private let alertsRepo: AlertsRepository
    private let medicationRepo: MedicationRepository
    private let graceWindow: TimeInterval

    init(stack: CoreDataStack = .shared,
         alertsRepo: AlertsRepository = AlertsRepository(),
         medicationRepo: MedicationRepository = MedicationRepository(),
         graceWindow: TimeInterval = MissedDoseDetector.defaultGraceWindow) {
        self.stack = stack
        self.alertsRepo = alertsRepo
        self.medicationRepo = medicationRepo
        self.graceWindow = graceWindow
    }

    /// Sweeps every dose-target in the circle for missed doses on
    /// `referenceDate`'s day. Returns the deterministic alert ids it
    /// tried to write — useful for tests, ignored by callers in prod.
    @discardableResult
    func run(in careCircleID: UUID, now: Date = Date()) async -> [String] {
        let _sp = Perf.signposter.beginInterval("detector.missedDose")
        defer { Perf.signposter.endInterval("detector.missedDose", _sp) }
        let cutoff = now.addingTimeInterval(-graceWindow)
        let people = await fetchClients(in: careCircleID)
        var attempted: [String] = []

        for person in people {
            guard let personID = person.id else { continue }
            let scheduled = await medicationRepo.fetchScheduledDoses(for: personID, on: now)

            // Pull every dose log for this person on the day so we can
            // check each scheduled dose against an existing record in
            // a single read instead of one per schedule.
            let (dayStart, dayEnd) = Self.dayBounds(for: now)
            let logs = await medicationRepo.fetchDoseLogs(
                for: nil, personID: personID, from: dayStart, to: dayEnd
            )

            for (medication, schedule) in scheduled {
                guard let medID = medication.id,
                      let timeString = schedule.timeOfDay,
                      let scheduledAt = Self.date(for: timeString, on: now) else { continue }
                if scheduledAt > cutoff { continue }   // not yet past grace

                let alreadyLogged = logs.contains { log in
                    guard let logMedID = log.medication?.id, logMedID == medID,
                          let logScheduled = log.scheduledTime else { return false }
                    return abs(logScheduled.timeIntervalSince(scheduledAt)) < 60
                }
                if alreadyLogged { continue }

                let alertID = AlertID.missedDose(
                    personID: personID,
                    medicationID: medID,
                    scheduledTime: scheduledAt
                )
                attempted.append(alertID)

                let alert = FirestoreModels.FAlert(
                    id: alertID,
                    type: FirestoreModels.AlertType.missedDose,
                    personID: personID.uuidString,
                    medicationID: medID.uuidString,
                    scheduledTime: scheduledAt,
                    createdAt: now,
                    payload: [
                        "medicationName": medication.name ?? "",
                        "personName": person.name ?? "",
                        "scheduledISO": ISO8601DateFormatter().string(from: scheduledAt)
                    ],
                    acknowledgedBy: nil,
                    acknowledgedByName: nil,
                    acknowledgedAt: nil,
                    lastModified: nil
                )
                _ = try? await alertsRepo.createIfAbsent(alert, in: careCircleID)
            }
        }

        return attempted
    }

    /// Test-visible helper.
    static func date(for timeOfDay: String, on day: Date, calendar: Calendar = .current) -> Date? {
        let parts = timeOfDay.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    private func fetchClients(in careCircleID: UUID) async -> [Person] {
        await stack.viewContext.perform { [stack] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(
                format: "careCircle.id == %@ AND (role == %@ OR role == %@)",
                careCircleID as CVarArg,
                Roles.deviceClient,
                Roles.managedClient
            )
            return (try? stack.viewContext.fetch(request)) ?? []
        }
    }

    private static func dayBounds(for date: Date, calendar: Calendar = .current) -> (Date, Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }
}
