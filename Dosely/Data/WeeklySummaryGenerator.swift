import CoreData
import Foundation

/// Drops a "this week's adherence" alert into the circle every Sunday
/// after 6pm local time, once. Runs from app launch and pull-to-refresh;
/// the deterministic alert id keyed on `weekly-{circleID}-{ISO date}`
/// makes it idempotent — multiple supervisor devices running the
/// generator on the same evening converge on a single doc.
///
/// "This week" means the seven days ending on the Sunday whose
/// 6pm-local-time has just passed. If the user opens the app on
/// Tuesday the generator returns nil — Tuesday isn't Sunday.
final class WeeklySummaryGenerator {
    /// 6pm — late enough that the day is mostly done, early enough
    /// that supervisors who open the app in the evening get the
    /// digest before bed.
    static let cutoffHour: Int = 18

    private let stack: CoreDataStack
    private let alertsRepo: AlertsRepository
    private let medicationRepo: MedicationRepository

    init(stack: CoreDataStack = .shared,
         alertsRepo: AlertsRepository = AlertsRepository(),
         medicationRepo: MedicationRepository = MedicationRepository()) {
        self.stack = stack
        self.alertsRepo = alertsRepo
        self.medicationRepo = medicationRepo
    }

    /// Returns the alertID on attempt (regardless of whether it
    /// landed first or hit the idempotency guard), or nil if the
    /// gating window says "not yet."
    @discardableResult
    func runIfDue(in careCircleID: UUID,
                  now: Date = Date(),
                  calendar: Calendar = .current) async -> String? {
        let _sp = Perf.signposter.beginInterval("detector.weeklySummary")
        defer { Perf.signposter.endInterval("detector.weeklySummary", _sp) }
        guard let weekEnding = Self.weekEndingSunday(for: now, calendar: calendar) else {
            return nil
        }

        let alertID = AlertID.weeklySummary(
            circleID: careCircleID,
            weekEndingSunday: weekEnding,
            calendar: calendar
        )

        let people = await fetchClients(in: careCircleID)
        let stats = await computeStats(for: people, weekEnding: weekEnding, calendar: calendar)
        if stats.isEmpty { return nil }

        let payload = Self.encodeStats(stats)
        let alert = FirestoreModels.FAlert(
            id: alertID,
            type: FirestoreModels.AlertType.weeklySummary,
            personID: people.first?.id?.uuidString ?? careCircleID.uuidString,
            medicationID: nil,
            scheduledTime: nil,
            createdAt: now,
            payload: payload,
            acknowledgedBy: nil,
            acknowledgedByName: nil,
            acknowledgedAt: nil,
            lastModified: nil
        )
        _ = try? await alertsRepo.createIfAbsent(alert, in: careCircleID)
        return alertID
    }

    // MARK: - Window math

    /// Returns the most recent Sunday whose 6pm-local cutoff has
    /// passed at `now`, or nil if it's any other day or the cutoff
    /// hasn't hit yet. Sunday before 6pm returns nil; Sunday after
    /// 6pm returns Sunday; Monday at any time returns nil.
    static func weekEndingSunday(for now: Date,
                                 calendar: Calendar = .current) -> Date? {
        let weekday = calendar.component(.weekday, from: now)
        // Calendar.weekday: Sunday == 1.
        guard weekday == 1 else { return nil }
        let hour = calendar.component(.hour, from: now)
        guard hour >= cutoffHour else { return nil }
        return calendar.startOfDay(for: now)
    }

    // MARK: - Stats

    struct PersonStats {
        let personID: UUID
        let personName: String
        let taken: Int
        let scheduled: Int
        var percent: Int {
            guard scheduled > 0 else { return 100 }
            return Int((Double(taken) / Double(scheduled) * 100).rounded())
        }
    }

    private func computeStats(for people: [Person],
                              weekEnding: Date,
                              calendar: Calendar) async -> [PersonStats] {
        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: weekEnding))
            ?? weekEnding.addingTimeInterval(-7 * 86_400)
        let weekEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: weekEnding))
            ?? weekEnding.addingTimeInterval(86_400)

        var out: [PersonStats] = []
        for person in people {
            guard let personID = person.id else { continue }
            let logs = await medicationRepo.fetchDoseLogs(
                for: nil, personID: personID, from: weekStart, to: weekEnd
            )
            let taken = logs.filter { $0.status == DoseStatus.taken.rawValue }.count
            let scheduled = logs.count
            out.append(PersonStats(
                personID: personID,
                personName: person.name ?? "",
                taken: taken,
                scheduled: scheduled
            ))
        }
        return out
    }

    /// Flattens the per-person stats into a Firestore-friendly map.
    /// `name|taken|scheduled` per personID, and a `_summary` line for
    /// the AlertsCard's body so it can render without parsing every
    /// row.
    static func encodeStats(_ stats: [PersonStats]) -> [String: String] {
        var map: [String: String] = [:]
        for s in stats {
            map[s.personID.uuidString] = "\(s.personName)|\(s.taken)|\(s.scheduled)"
        }
        let totalTaken = stats.reduce(0) { $0 + $1.taken }
        let totalScheduled = stats.reduce(0) { $0 + $1.scheduled }
        map["_summary"] = "\(totalTaken)|\(totalScheduled)"
        return map
    }

    // MARK: - Helpers

    private func fetchClients(in careCircleID: UUID) async -> [Person] {
        await stack.viewContext.perform { [stack] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(
                format: "careCircle.id == %@ AND (role == %@ OR role == %@)",
                careCircleID as CVarArg,
                Roles.deviceClient,
                Roles.managedClient
            )
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            return (try? stack.viewContext.fetch(request)) ?? []
        }
    }
}
