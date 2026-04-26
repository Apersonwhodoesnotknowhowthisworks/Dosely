import Foundation

struct MissedDoseChecker {
    let repository: MedicationRepository

    // A dose that's more than this many seconds past its scheduled time and still
    // unlogged is written as "late"; past the missed threshold it's "missed".
    static let lateThreshold: TimeInterval   = 30 * 60
    static let missedThreshold: TimeInterval = 2 * 60 * 60

    /// Runs the late/missed sweep for one Person. The system itself is the
    /// "logger" for late/missed entries — `loggedByPersonID` is set to
    /// `personID` because no actual user marked it; the row is a marker
    /// that nobody acted in time.
    func run(for personID: UUID, now: Date = Date()) async {
        let scheduled = await repository.fetchScheduledDoses(for: personID, on: now)

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let logs = await repository.fetchDoseLogs(for: nil, personID: personID,
                                                  from: dayStart, to: dayEnd)

        for (med, schedule) in scheduled {
            guard let medID = med.id,
                  let scheduledTime = Self.scheduledDate(for: schedule.timeOfDay, on: now)
            else { continue }

            let elapsed = now.timeIntervalSince(scheduledTime)
            guard elapsed > Self.lateThreshold else { continue }

            let alreadyLogged = logs.contains { log in
                guard let logMedID = log.medication?.id, logMedID == medID else { return false }
                return abs((log.scheduledTime ?? .distantPast).timeIntervalSince(scheduledTime)) < 60
            }
            guard !alreadyLogged else { continue }

            let status = elapsed > Self.missedThreshold ? "missed" : "late"
            _ = await repository.logDose(
                medicationID: medID,
                scheduledTime: scheduledTime,
                actualTime: nil,
                status: status,
                loggedByPersonID: personID
            )
        }
    }

    private static func scheduledDate(for hhmm: String?, on day: Date) -> Date? {
        guard let hhmm else { return nil }
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: day)
    }
}
