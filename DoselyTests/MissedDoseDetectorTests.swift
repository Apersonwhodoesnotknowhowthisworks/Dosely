import CoreData
import XCTest
@testable import Dosely

/// Pure-logic tests for `MissedDoseDetector`. The detector reads
/// people, schedules, and dose logs from Core Data and writes alerts
/// via `AlertsRepository.createIfAbsent` — but with a no-op
/// `FirestoreService` (db == nil) the create fails offline, the
/// detector swallows it, and the returned `attempted` array shows
/// exactly which alerts the detector wanted to write. That's all we
/// need to verify gap detection, grace window, and idempotent ids.
final class MissedDoseDetectorTests: XCTestCase {
    var stack: CoreDataStack!
    var personRepo: PersonRepository!
    var medRepo: MedicationRepository!
    var careCircleRepo: CareCircleRepository!
    var alertsRepo: AlertsRepository!
    var detector: MissedDoseDetector!
    var circle: CareCircle!
    var supervisor: Person!
    var grandpa: Person!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        let noFirestore = FirestoreService()
        personRepo = PersonRepository(stack: stack, firestore: noFirestore)
        medRepo = MedicationRepository(stack: stack, firestore: noFirestore)
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        alertsRepo = AlertsRepository(stack: stack, firestore: noFirestore)
        detector = MissedDoseDetector(
            stack: stack,
            alertsRepo: alertsRepo,
            medicationRepo: medRepo,
            graceWindow: 30 * 60
        )
        circle = await careCircleRepo.createCareCircle(
            name: "T", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        supervisor = await personRepo.fetchSupervisor(firebaseUID: "f")
        grandpa = try await personRepo.createManagedClient(
            name: "Grandpa", photoData: nil, language: "en",
            in: circle, actorPersonID: supervisor.id!
        )
    }

    override func tearDown() {
        stack = nil; personRepo = nil; medRepo = nil
        careCircleRepo = nil; alertsRepo = nil; detector = nil
        circle = nil; supervisor = nil; grandpa = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func seedMedAndSchedule(timeOfDay: String,
                                    name: String = "Lipitor",
                                    daysOfWeek: Int16 = 127) async throws -> Medication {
        let med = try await medRepo.saveMedication(
            personID: grandpa.id!,
            actorPersonID: supervisor.id!,
            name: name,
            dose: "10mg",
            pillsPerDose: 1,
            foodRule: "either",
            notes: nil,
            currentSupply: 30,
            pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: timeOfDay, daysOfWeek: daysOfWeek)]
        )
        return med
    }

    private func logTaken(med: Medication, scheduledAt: Date) async {
        _ = await medRepo.logDose(
            medicationID: med.id!,
            scheduledTime: scheduledAt,
            actualTime: scheduledAt,
            status: DoseStatus.taken.rawValue,
            loggedByPersonID: supervisor.id!
        )
    }

    private func date(hour: Int, minute: Int, on day: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    // MARK: - Detection

    /// A scheduled dose that's well past its time and has no DoseLog
    /// yields exactly one alert with the deterministic id.
    func testDetectsAGapAndMintsTheCanonicalAlertID() async throws {
        let now = date(hour: 12, minute: 0, on: Date())
        let scheduledAt = date(hour: 8, minute: 0, on: now)
        let med = try await seedMedAndSchedule(timeOfDay: "08:00")

        let attempted = await detector.run(in: circle.id!, now: now)

        XCTAssertEqual(attempted.count, 1, "one missed dose should yield one alert")
        let expected = AlertID.missedDose(
            personID: grandpa.id!,
            medicationID: med.id!,
            scheduledTime: scheduledAt
        )
        XCTAssertEqual(attempted.first, expected,
                       "alert id must be deterministic on (personID, medicationID, scheduledTime)")
    }

    /// A scheduled dose that's still within the grace window doesn't
    /// trigger an alert. Catch-and-tap users get a 30-minute buffer.
    func testRespectsTheGraceWindow() async throws {
        let now = date(hour: 8, minute: 15, on: Date())
        _ = try await seedMedAndSchedule(timeOfDay: "08:00")

        let attempted = await detector.run(in: circle.id!, now: now)

        XCTAssertTrue(attempted.isEmpty,
                      "15 minutes is inside the 30-minute grace — no alert yet")
    }

    /// A dose that's already been taken doesn't generate an alert
    /// even if scheduledTime is hours past — the matching DoseLog is
    /// the all-clear signal.
    func testIgnoresDosesThatAlreadyHaveALog() async throws {
        let now = date(hour: 14, minute: 0, on: Date())
        let scheduledAt = date(hour: 8, minute: 0, on: now)
        let med = try await seedMedAndSchedule(timeOfDay: "08:00")
        await logTaken(med: med, scheduledAt: scheduledAt)

        let attempted = await detector.run(in: circle.id!, now: now)

        XCTAssertTrue(attempted.isEmpty,
                      "matching DoseLog clears the gap — no alert")
    }

    /// Two missed doses on different schedules produce two distinct
    /// alert ids. Confirms the id derivation includes the scheduled
    /// time, not just the (person, med) pair.
    func testTwoDistinctScheduleSlotsYieldTwoAlerts() async throws {
        let now = date(hour: 21, minute: 0, on: Date())
        let med = try await seedMedAndSchedule(timeOfDay: "08:00")
        // Add a second schedule to the same med via the repo.
        try await medRepo.replaceSchedules(
            for: med.id!,
            actorPersonID: supervisor.id!,
            schedules: [
                ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127),
                ScheduleInput(timeOfDay: "20:00", daysOfWeek: 127)
            ]
        )

        let attempted = await detector.run(in: circle.id!, now: now)

        XCTAssertEqual(attempted.count, 2)
        XCTAssertEqual(Set(attempted).count, 2,
                       "alert ids must differ when scheduledTime differs")
    }

    /// Running the detector twice in a row yields the same ids both
    /// times — that's the idempotency contract callers rely on.
    func testRunIsIdempotent() async throws {
        let now = date(hour: 12, minute: 0, on: Date())
        _ = try await seedMedAndSchedule(timeOfDay: "08:00")

        let first = await detector.run(in: circle.id!, now: now)
        let second = await detector.run(in: circle.id!, now: now)

        XCTAssertEqual(first, second,
                       "detector with same inputs must produce identical alert ids")
    }
}
