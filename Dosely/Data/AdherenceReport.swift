import CoreData
import Foundation

/// A patient's adherence over a date range, ready to be formatted into an
/// email. Built purely from already-loaded medications and dose logs — no I/O —
/// so it's deterministic and trivially testable.
struct AdherenceReport {
    let patientName: String
    let dateRange: ClosedRange<Date>
    let medications: [MedicationSummary]
    let overallTakenCount: Int
    let overallScheduledCount: Int
    let missedDoses: [MissedDose]

    var overallPercent: Int {
        guard overallScheduledCount > 0 else { return 0 }
        return Int((Double(overallTakenCount) / Double(overallScheduledCount) * 100).rounded())
    }

    struct MedicationSummary: Identifiable {
        let id: UUID
        let name: String
        let dose: String
        let takenCount: Int
        let scheduledCount: Int
        var percent: Int {
            guard scheduledCount > 0 else { return 0 }
            return Int((Double(takenCount) / Double(scheduledCount) * 100).rounded())
        }
    }

    struct MissedDose: Identifiable {
        let id = UUID()
        let medicationName: String
        let scheduledAt: Date
    }
}

extension AdherenceReport {
    /// Build the report from already-loaded medications + dose logs. Pure: no
    /// Core Data fetches, no Firestore.
    ///
    /// Adherence basis matches the dashboard's `PersonAdherence` exactly —
    /// taken / (taken + missed), counting only LOGGED doses. "Skipped" is an
    /// intentional choice and excluded; "late" is a transient pre-missed state
    /// and also excluded; same as the dashboard, so the emailed figure and the
    /// dashboard card can never disagree (different windows, identical formula).
    /// `MissedDoseChecker` marks unlogged past doses "missed", so this
    /// status-based count is equivalent to "a scheduled dose with no taken log."
    static func build(patientName: String,
                      medications: [Medication],
                      doseLogs: [DoseLog],
                      in dateRange: ClosedRange<Date>) -> AdherenceReport {
        let taken = DoseStatus.taken.rawValue
        let missed = DoseStatus.missed.rawValue

        // Only logs whose scheduled time falls inside the range count.
        let inRange = doseLogs.filter { log in
            guard let when = log.scheduledTime else { return false }
            return dateRange.contains(when)
        }

        var summaries: [MedicationSummary] = []
        var overallTaken = 0
        var overallScheduled = 0
        for med in medications {
            guard let medID = med.id else { continue }
            let medLogs = inRange.filter { $0.medication?.id == medID }
            let takenCount = medLogs.filter { $0.status == taken }.count
            let missedCount = medLogs.filter { $0.status == missed }.count
            let scheduledCount = takenCount + missedCount
            overallTaken += takenCount
            overallScheduled += scheduledCount
            summaries.append(MedicationSummary(
                id: medID,
                name: med.name ?? "",
                dose: med.dose ?? "",
                takenCount: takenCount,
                scheduledCount: scheduledCount
            ))
        }

        let missedLogs = inRange.filter { $0.status == missed }
        let sortedMissed = missedLogs.sorted {
            ($0.scheduledTime ?? .distantPast) < ($1.scheduledTime ?? .distantPast)
        }
        let missedDoses: [MissedDose] = sortedMissed.map { log in
            MissedDose(medicationName: log.medication?.name ?? "",
                       scheduledAt: log.scheduledTime ?? Date())
        }

        return AdherenceReport(
            patientName: patientName,
            dateRange: dateRange,
            medications: summaries,
            overallTakenCount: overallTaken,
            overallScheduledCount: overallScheduled,
            missedDoses: missedDoses
        )
    }
}
