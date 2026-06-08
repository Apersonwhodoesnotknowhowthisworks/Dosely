import CoreData
import Foundation
import SwiftUI

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
    @Published private(set) var alerts: [Alert] = []
    /// Cross-medication interactions for the currently-selected single patient
    /// (empty in the "All" view, where pairwise interactions don't apply).
    /// Recomputed on every `load`, so adding or removing a medication and
    /// reloading surfaces or clears the banner.
    @Published private(set) var interactions: [DrugInteraction] = []
    @Published private(set) var isLoaded = false
    /// Reactive primary-supervisor flag for the acting user. Plain
    /// `authService.currentPerson?.role` reads through @EnvironmentObject
    /// don't invalidate the SwiftUI view when the underlying Core Data
    /// row's `role` or its CareCircle's `primarySupervisorPersonID`
    /// mutate — SwiftUI tracks the @Published wrapper, not nested
    /// NSManagedObject property writes. Listener-driven promotions
    /// (the other supervisor's device demotes us) therefore left the
    /// dashboard's role badge, QuickActionsCard, and write affordances
    /// in their pre-transition state until a tab change forced a
    /// re-render. This property reads through Core Data each time the
    /// viewContext fires `ObjectsDidChange`, which catches both
    /// listener mirrors and direct viewContext writes.
    @Published private(set) var actorIsPrimary: Bool = false

    private let medicationRepo: MedicationRepository
    private let personRepo: PersonRepository
    private let alertsRepo: AlertsRepository
    private let missedDoseDetector: MissedDoseDetector
    private let weeklySummaryGenerator: WeeklySummaryGenerator
    private let refillAlertDetector: RefillAlertDetector
    private let stack: CoreDataStack
    private var actorObserver: NSObjectProtocol?
    private var actorPersonID: UUID?

    init(medicationRepo: MedicationRepository = MedicationRepository(),
         personRepo: PersonRepository = PersonRepository(),
         alertsRepo: AlertsRepository = AlertsRepository(),
         missedDoseDetector: MissedDoseDetector = MissedDoseDetector(),
         weeklySummaryGenerator: WeeklySummaryGenerator = WeeklySummaryGenerator(),
         refillAlertDetector: RefillAlertDetector = RefillAlertDetector(),
         stack: CoreDataStack = .shared) {
        self.medicationRepo = medicationRepo
        self.personRepo = personRepo
        self.alertsRepo = alertsRepo
        self.missedDoseDetector = missedDoseDetector
        self.weeklySummaryGenerator = weeklySummaryGenerator
        self.refillAlertDetector = refillAlertDetector
        self.stack = stack
    }

    deinit {
        if let actorObserver {
            NotificationCenter.default.removeObserver(actorObserver)
        }
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
        let _sp = Perf.signposter.beginInterval("dashboard.load")
        defer { Perf.signposter.endInterval("dashboard.load", _sp) }
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
            let meds = await medicationRepo.fetchAllMedications(for: activePersonID)
            self.interactions = DrugInteractionService.shared.allInteractionsFor(patient: meds)
        } else {
            self.doses = await loadCombinedDoses(across: onlyClients, now: now)
            self.adherence = nil
            self.interactions = []
        }

        // Run the detectors before reading the inbox so any new
        // gaps surface in the same load. Both are idempotent — calls
        // from sibling supervisor devices converge on a single doc
        // via deterministic alert ids.
        await missedDoseDetector.run(in: circleID, now: now)
        await weeklySummaryGenerator.runIfDue(in: circleID, now: now)
        await refillAlertDetector.run(in: circleID, now: now)
        self.alerts = await alertsRepo.fetchAlerts(in: circleID)

        self.actorIsPrimary = await personRepo.isPrimary(personID: supervisorID)
        startObservingActor(personID: supervisorID)

        self.isLoaded = true
    }

    /// Begins (or re-targets) the Core Data observer that keeps
    /// `actorIsPrimary` reactive to listener-driven mirrors of the
    /// actor's Person row or CareCircle.primarySupervisorPersonID.
    /// Idempotent for the same `personID` — calling with a new id
    /// tears down the previous subscription first.
    private func startObservingActor(personID: UUID) {
        if actorPersonID == personID, actorObserver != nil { return }
        if let actorObserver {
            NotificationCenter.default.removeObserver(actorObserver)
        }
        actorPersonID = personID
        let viewContext = stack.viewContext
        actorObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: viewContext,
            queue: .main
        ) { [weak self] _ in
            // The notification fires on background-context merges into
            // the view context too (because `automaticallyMergesChangesFromParent`
            // is on) so listener-driven role flips reach us here.
            Task { @MainActor [weak self] in
                guard let self, let personID = self.actorPersonID else { return }
                let next = await self.personRepo.isPrimary(personID: personID)
                if next != self.actorIsPrimary { self.actorIsPrimary = next }
            }
        }
    }

    /// First-to-acknowledge clears it for everyone. Hits the atomic
    /// transaction in `AlertsRepository`; on success the listener
    /// will reconcile the local mirror, but we also reload immediately
    /// so the UI doesn't sit stale waiting for the snapshot.
    func acknowledge(_ alert: Alert,
                     supervisorID: UUID,
                     supervisorFirebaseUID: String,
                     supervisorName: String?,
                     activePersonID: UUID?,
                     circleID: UUID) async {
        guard let docID = alert.docID else { return }
        do {
            try await alertsRepo.acknowledge(
                alertID: docID,
                in: circleID,
                firebaseUID: supervisorFirebaseUID,
                actorName: supervisorName
            )
        } catch {
            // Surface nothing in the UI yet — the listener will reconcile
            // when network returns. Reload below picks up any change.
        }
        await load(circleID: circleID,
                   supervisorID: supervisorID,
                   activePersonID: activePersonID)
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
