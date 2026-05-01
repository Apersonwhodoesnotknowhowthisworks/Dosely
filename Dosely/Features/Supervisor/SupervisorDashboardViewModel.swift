import Foundation
import SwiftUI

/// One row in the AlertsCard. For Prompt 14 the data is stubbed with a
/// fixed sample; Prompt 15 wires real signals (missed-dose rollups, low
/// supply, PIN lockout, emergency button).
struct DashboardAlert: Identifiable, Hashable {
    enum Severity { case info, warning, danger }

    let id: UUID
    let title: String
    let body: String
    let severity: Severity

    init(id: UUID = UUID(), title: String, body: String, severity: Severity) {
        self.id = id
        self.title = title
        self.body = body
        self.severity = severity
    }
}

/// One person's adherence rollup for the current week.
struct PersonAdherence: Identifiable, Hashable {
    let id: UUID                // == person.id
    let personName: String
    let takenCount: Int
    let scheduledCount: Int

    var percent: Int {
        guard scheduledCount > 0 else { return 100 }
        return Int((Double(takenCount) / Double(scheduledCount) * 100).rounded())
    }
}

/// `nil` activePersonID means "All" — the combined view across every
/// client in the care circle.
@MainActor
final class SupervisorDashboardViewModel: ObservableObject {
    @Published private(set) var clients: [Person] = []
    @Published private(set) var doses: [TodayDose] = []
    @Published private(set) var adherence: PersonAdherence?
    @Published private(set) var alerts: [DashboardAlert] = []
    @Published private(set) var isLoaded = false

    private let medicationRepo: MedicationRepository
    private let personRepo: PersonRepository

    init(medicationRepo: MedicationRepository = MedicationRepository(),
         personRepo: PersonRepository = PersonRepository()) {
        self.medicationRepo = medicationRepo
        self.personRepo = personRepo
    }

    /// Loads the dashboard data for the supervisor.
    /// - circleID: the supervisor's care circle.
    /// - supervisorID: the acting supervisor's Person.id (used as the
    ///   default `loggedByPersonID` for "log on grandma's behalf").
    /// - activePersonID: nil = "All", non-nil = single client view.
    func load(circleID: UUID,
              supervisorID: UUID,
              activePersonID: UUID?,
              now: Date = Date()) async {
        let allPeople = await personRepo.fetchAllPeople(in: circleID)
        // Filter by role, not by id. The selector and the dose-aggregation
        // paths below only make sense for dose-targets — co-supervisors
        // are caregivers, not patients, and previously slipped in because
        // we only excluded the *acting* supervisor. Per the data model
        // (CLAUDE.md) both device_client and managed_client are valid
        // dose-targets; every supervisor flavor (including the legacy
        // alias) is excluded.
        let onlyClients = allPeople
            .filter { $0.role == Roles.deviceClient || $0.role == Roles.managedClient }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
        self.clients = onlyClients

        if let activePersonID {
            self.doses = await loadDoses(for: activePersonID, now: now)
            self.adherence = await computeAdherence(for: activePersonID, in: onlyClients, now: now)
            self.alerts = stubAlerts(for: activePersonID, clients: onlyClients)
        } else {
            self.doses = await loadCombinedDoses(across: onlyClients, now: now)
            self.adherence = nil
            self.alerts = stubAlerts(for: nil, clients: onlyClients)
        }

        self.isLoaded = true
    }

    func markTaken(_ dose: TodayDose,
                   supervisorID: UUID,
                   activePersonID: UUID?,
                   circleID: UUID,
                   at actualTime: Date = Date()) async {
        guard let medID = dose.medication.id else { return }
        _ = await medicationRepo.logDose(
            medicationID: medID,
            scheduledTime: dose.scheduledDate,
            actualTime: actualTime,
            status: DoseStatus.taken.rawValue,
            loggedByPersonID: supervisorID
        )
        await load(circleID: circleID,
                   supervisorID: supervisorID,
                   activePersonID: activePersonID)
    }

    func skip(_ dose: TodayDose,
              supervisorID: UUID,
              activePersonID: UUID?,
              circleID: UUID) async {
        guard let medID = dose.medication.id else { return }
        _ = await medicationRepo.logDose(
            medicationID: medID,
            scheduledTime: dose.scheduledDate,
            actualTime: nil,
            status: DoseStatus.skipped.rawValue,
            loggedByPersonID: supervisorID
        )
        await load(circleID: circleID,
                   supervisorID: supervisorID,
                   activePersonID: activePersonID)
    }

    // MARK: - Internals

    private func loadDoses(for personID: UUID, now: Date) async -> [TodayDose] {
        let scheduled = await medicationRepo.fetchScheduledDoses(for: personID, on: now)
        let (dayStart, dayEnd) = Self.dayBounds(for: now)
        let logs = await medicationRepo.fetchDoseLogs(for: nil,
                                                      personID: personID,
                                                      from: dayStart,
                                                      to: dayEnd)
        return scheduled.compactMap { (med, schedule) -> TodayDose? in
            guard
                let scheduleID = schedule.id,
                let scheduled = TodayViewModel.date(for: schedule.timeOfDay ?? "08:00", on: now)
            else { return nil }
            let match = logs.first { log in
                guard let logMedID = log.medication?.id, let medID = med.id,
                      logMedID == medID else { return false }
                return abs((log.scheduledTime ?? .distantPast).timeIntervalSince(scheduled)) < 60
            }
            return TodayDose(id: scheduleID,
                             medication: med,
                             schedule: schedule,
                             scheduledDate: scheduled,
                             log: match)
        }
        .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private func loadCombinedDoses(across clients: [Person], now: Date) async -> [TodayDose] {
        var combined: [TodayDose] = []
        for client in clients {
            guard let pid = client.id else { continue }
            combined.append(contentsOf: await loadDoses(for: pid, now: now))
        }
        return combined.sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private func computeAdherence(for personID: UUID,
                                  in clients: [Person],
                                  now: Date) async -> PersonAdherence? {
        guard let person = clients.first(where: { $0.id == personID }),
              let pid = person.id else { return nil }
        let (weekStart, weekEnd) = Self.weekBounds(for: now)
        let logs = await medicationRepo.fetchDoseLogs(for: nil,
                                                      personID: pid,
                                                      from: weekStart,
                                                      to: weekEnd)
        // Adherence = taken / (taken + missed). Skipped is intentional and
        // doesn't count against the patient. Pure "scheduled" counts would
        // double-count days in the future of the current week; the simpler,
        // honest measure is over what's been logged so far.
        let taken = logs.filter { $0.status == "taken" }.count
        let missed = logs.filter { $0.status == "missed" }.count
        let denom = taken + missed
        return PersonAdherence(id: pid,
                               personName: person.name ?? "",
                               takenCount: taken,
                               scheduledCount: denom)
    }

    /// Stubbed alerts — replaced in Prompt 15. Returns a fixed sample so
    /// the AlertsCard has visible content during dashboard development.
    private func stubAlerts(for activePersonID: UUID?, clients: [Person]) -> [DashboardAlert] {
        guard let activePersonID,
              let person = clients.first(where: { $0.id == activePersonID }) else {
            return []
        }
        let firstName = (person.name ?? "").components(separatedBy: " ").first ?? ""
        return [
            DashboardAlert(title: L("supervisor.alerts.stub.refill.title"),
                           body: L("supervisor.alerts.stub.refill.body", firstName as NSString),
                           severity: .warning)
        ]
    }

    // MARK: - Date helpers

    private static func dayBounds(for date: Date, calendar: Calendar = .current) -> (Date, Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    private static func weekBounds(for date: Date, calendar: Calendar = .current) -> (Date, Date) {
        var cal = calendar
        cal.firstWeekday = 2  // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let start = cal.date(from: comps) ?? cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
        return (start, end)
    }
}
