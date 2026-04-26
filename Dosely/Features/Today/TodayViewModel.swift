import Foundation
import SwiftUI

enum DoseStatus: String {
    case upcoming, taken, late, missed, skipped
}

struct TodayDose: Identifiable {
    let id: UUID              // schedule.id — stable across reloads
    let medication: Medication
    let schedule: DoseSchedule
    let scheduledDate: Date   // schedule.timeOfDay projected onto today
    let log: DoseLog?

    var status: DoseStatus {
        if let raw = log?.status, let parsed = DoseStatus(rawValue: raw) { return parsed }
        return .upcoming
    }
}

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var doses: [TodayDose] = []
    @Published private(set) var isLoaded = false

    private let repository: MedicationRepository

    init(repository: MedicationRepository = MedicationRepository()) {
        self.repository = repository
    }

    /// Loads today's scheduled doses for `personID`, joined with the
    /// person's logs for the day. `loggedByPersonID` is recorded against
    /// any new logs the user creates from this screen (the actor doing
    /// the logging — typically the same as `personID` for a device client,
    /// or the supervisor when logging on behalf of a managed client).
    func load(personID: UUID, now: Date = Date()) async {
        let scheduled = await repository.fetchScheduledDoses(for: personID, on: now)

        let (dayStart, dayEnd) = Self.dayBounds(for: now)
        let logs = await repository.fetchDoseLogs(for: nil, personID: personID, from: dayStart, to: dayEnd)

        let items: [TodayDose] = scheduled.compactMap { (med, schedule) in
            guard
                let scheduleID = schedule.id,
                let scheduled = Self.date(for: schedule.timeOfDay ?? "08:00", on: now)
            else { return nil }

            let match = logs.first { log in
                guard let logMedID = log.medication?.id, let medID = med.id else { return false }
                guard logMedID == medID else { return false }
                return abs((log.scheduledTime ?? .distantPast).timeIntervalSince(scheduled)) < 60
            }
            return TodayDose(
                id: scheduleID,
                medication: med,
                schedule: schedule,
                scheduledDate: scheduled,
                log: match
            )
        }
        .sorted { $0.scheduledDate < $1.scheduledDate }

        self.doses = items
        self.isLoaded = true
    }

    func markTaken(
        _ dose: TodayDose,
        loggedByPersonID: UUID,
        personID: UUID,
        at actualTime: Date = Date()
    ) async {
        guard let medID = dose.medication.id else { return }
        _ = await repository.logDose(
            medicationID: medID,
            scheduledTime: dose.scheduledDate,
            actualTime: actualTime,
            status: DoseStatus.taken.rawValue,
            loggedByPersonID: loggedByPersonID
        )
        await load(personID: personID)
    }

    func skip(
        _ dose: TodayDose,
        loggedByPersonID: UUID,
        personID: UUID
    ) async {
        guard let medID = dose.medication.id else { return }
        _ = await repository.logDose(
            medicationID: medID,
            scheduledTime: dose.scheduledDate,
            actualTime: nil,
            status: DoseStatus.skipped.rawValue,
            loggedByPersonID: loggedByPersonID
        )
        await load(personID: personID)
    }

    // MARK: - Helpers

    private static func dayBounds(for date: Date, calendar: Calendar = .current) -> (Date, Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    static func date(for timeOfDay: String, on day: Date, calendar: Calendar = .current) -> Date? {
        let parts = timeOfDay.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return calendar.date(bySettingHour: h, minute: m, second: 0, of: day)
    }
}
