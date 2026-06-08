import CoreData
import Foundation

/// Sweeps every scheduled medication in a care circle and writes a `refill`
/// alert for each one whose supply has dropped below the threshold — as long
/// as no unacknowledged refill alert already stands for that medication, so a
/// med that's been low for days doesn't pile a fresh alert into the inbox on
/// every run.
///
/// Idempotent like `MissedDoseDetector`: the alert id is deterministic per
/// (medication, day), so concurrent supervisor devices detecting the same low
/// supply on the same day converge on one doc — only the first
/// `AlertsRepository.createIfAbsent` lands, the rest get a benign false back.
///
/// Cadence mirrors `MissedDoseDetector`: `SupervisorDashboardViewModel.load`,
/// the dashboard's foreground re-fire, and the 5-minute `TodayView` timer all
/// call it. On a pure device-client surface the alert create is denied by the
/// `isAnySupervisor` rule and swallowed (same as the missed-dose detector); a
/// supervisor's device — or the shared device where the supervisor is the
/// signed-in Firebase user — creates it.
final class RefillAlertDetector {
    private let stack: CoreDataStack
    private let alertsRepo: AlertsRepository
    private let calculator: RefillSupplyCalculator.Type

    init(stack: CoreDataStack = .shared,
         alertsRepo: AlertsRepository = AlertsRepository(),
         calculator: RefillSupplyCalculator.Type = RefillSupplyCalculator.self) {
        self.stack = stack
        self.alertsRepo = alertsRepo
        self.calculator = calculator
    }

    /// Returns the deterministic alert ids it tried to write — useful for
    /// tests, ignored by callers in production.
    @discardableResult
    func run(in careCircleID: UUID, now: Date = Date()) async -> [String] {
        let _sp = Perf.signposter.beginInterval("detector.refillAlert")
        defer { Perf.signposter.endInterval("detector.refillAlert", _sp) }
        let candidates = await fetchLowSupplyCandidates(in: careCircleID, now: now)
        var attempted: [String] = []
        for candidate in candidates {
            attempted.append(candidate.alertID)
            let alert = FirestoreModels.FAlert(
                id: candidate.alertID,
                type: FirestoreModels.AlertType.refill,
                personID: candidate.personID.uuidString,
                medicationID: candidate.medicationID.uuidString,
                scheduledTime: nil,
                createdAt: now,
                payload: candidate.payload,
                acknowledgedBy: nil,
                acknowledgedByName: nil,
                acknowledgedAt: nil,
                lastModified: nil
            )
            _ = try? await alertsRepo.createIfAbsent(alert, in: careCircleID)
        }
        return attempted
    }

    private struct Candidate {
        let alertID: String
        let personID: UUID
        let medicationID: UUID
        let payload: [String: String]
    }

    /// Low-supply medications in the circle that don't already have an
    /// unacknowledged refill alert, each packaged with its deterministic id
    /// and payload. Pure read on the view context — no writes here.
    private func fetchLowSupplyCandidates(in careCircleID: UUID, now: Date) async -> [Candidate] {
        await stack.viewContext.perform { [stack, calculator] in
            let ctx = stack.viewContext

            let peopleReq = NSFetchRequest<Person>(entityName: "Person")
            peopleReq.predicate = NSPredicate(
                format: "careCircle.id == %@ AND (role == %@ OR role == %@)",
                careCircleID as CVarArg, Roles.deviceClient, Roles.managedClient
            )
            let people = (try? ctx.fetch(peopleReq)) ?? []

            // One pending refill alert per medication at a time: skip any med
            // that already has an unacknowledged refill alert.
            let alertReq = NSFetchRequest<Alert>(entityName: "Alert")
            alertReq.predicate = NSPredicate(
                format: "careCircle.id == %@ AND type == %@",
                careCircleID as CVarArg, FirestoreModels.AlertType.refill
            )
            let pendingMedIDs: Set<UUID> = Set(
                ((try? ctx.fetch(alertReq)) ?? [])
                    .filter { ($0.acknowledgedByFirebaseUID ?? "").isEmpty }
                    .compactMap { $0.medicationID }
            )

            var candidates: [Candidate] = []
            for person in people {
                guard let personID = person.id else { continue }
                let medReq = NSFetchRequest<Medication>(entityName: "Medication")
                medReq.predicate = NSPredicate(format: "personID == %@", personID as CVarArg)
                for med in (try? ctx.fetch(medReq)) ?? [] {
                    guard let medID = med.id,
                          calculator.isLow(for: med),
                          let days = calculator.daysRemaining(for: med),
                          !pendingMedIDs.contains(medID) else { continue }

                    let runOut = now.addingTimeInterval(days * 86_400)
                    let payload: [String: String] = [
                        "medicationName": med.name ?? "",
                        "personName": person.name ?? "",
                        "daysRemaining": String(Int(days.rounded())),
                        "currentSupply": String(Int(med.currentSupply)),
                        "runOutDate": LocalizedFormatters.dateFormatter(format: "MMM d, yyyy").string(from: runOut)
                    ]
                    candidates.append(Candidate(
                        alertID: AlertID.refill(medicationID: medID, date: now),
                        personID: personID,
                        medicationID: medID,
                        payload: payload
                    ))
                }
            }
            return candidates
        }
    }
}
