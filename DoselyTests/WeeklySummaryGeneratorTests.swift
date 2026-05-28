import CoreData
import XCTest
@testable import Dosely

/// Tests for `WeeklySummaryGenerator`. The generator only fires Sunday
/// after 6pm, computes per-person adherence from the past seven days
/// of DoseLogs, and writes an alert with a deterministic id derived
/// from `(circleID, weekEndingSunday)`.
final class WeeklySummaryGeneratorTests: XCTestCase {
    var stack: CoreDataStack!
    var personRepo: PersonRepository!
    var medRepo: MedicationRepository!
    var careCircleRepo: CareCircleRepository!
    var alertsRepo: AlertsRepository!
    var generator: WeeklySummaryGenerator!
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
        generator = WeeklySummaryGenerator(
            stack: stack,
            alertsRepo: alertsRepo,
            medicationRepo: medRepo
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
        careCircleRepo = nil; alertsRepo = nil; generator = nil
        circle = nil; supervisor = nil; grandpa = nil
        super.tearDown()
    }

    // MARK: - Window math

    /// Sunday at 6pm exactly counts. Sunday at 5:59pm doesn't —
    /// supervisors who open the app over Sunday lunch shouldn't get
    /// the digest yet.
    func testWeekEndingSundayGatedAtSixPM() {
        let calendar = gregorian()
        let sundayMorning = makeDate(year: 2026, month: 5, day: 3, hour: 9, calendar: calendar)
        let sundayDinner = makeDate(year: 2026, month: 5, day: 3, hour: 18, calendar: calendar)
        let mondayMorning = makeDate(year: 2026, month: 5, day: 4, hour: 9, calendar: calendar)

        XCTAssertNil(WeeklySummaryGenerator.weekEndingSunday(for: sundayMorning, calendar: calendar),
                     "Sunday before 6pm — not yet")
        XCTAssertNotNil(WeeklySummaryGenerator.weekEndingSunday(for: sundayDinner, calendar: calendar),
                        "Sunday at 6pm — fire")
        XCTAssertNil(WeeklySummaryGenerator.weekEndingSunday(for: mondayMorning, calendar: calendar),
                     "Monday — already past, generator only runs Sunday")
    }

    /// Pins the user-facing contract in LOCAL time, with an explicit
    /// zone so the result is identical on any test machine (the prior
    /// version built dates in UTC but evaluated in the machine's zone,
    /// so it only passed on a UTC box). A grandparent in BC gets her
    /// digest at *her* Sunday 6pm, not UTC's: Saturday 23:59 → not yet;
    /// Sunday 18:00:00 → fires; the following Monday 09:00 → the gate
    /// is a Sunday-only window so it declines again (the deterministic
    /// id is what blocks a second write within the same Sunday).
    func testGateFiresOnlyAtSundaySixPMLocal() {
        let calendar = gregorian()  // America/Vancouver

        let saturdayNight = makeDate(year: 2026, month: 5, day: 2, hour: 23, minute: 59, calendar: calendar)
        XCTAssertNil(WeeklySummaryGenerator.weekEndingSunday(for: saturdayNight, calendar: calendar),
                     "Saturday 23:59 local — the week hasn't ended yet")

        let sundaySixPM = makeDate(year: 2026, month: 5, day: 3, hour: 18, minute: 0, calendar: calendar)
        XCTAssertNotNil(WeeklySummaryGenerator.weekEndingSunday(for: sundaySixPM, calendar: calendar),
                        "Sunday 18:00:00 local — the gate fires")

        let mondayMorning = makeDate(year: 2026, month: 5, day: 4, hour: 9, calendar: calendar)
        XCTAssertNil(WeeklySummaryGenerator.weekEndingSunday(for: mondayMorning, calendar: calendar),
                     "Monday 09:00 local — Sunday-only window has closed; the deterministic id blocks a re-fire")
    }

    /// `runIfDue` returns nil on a non-Sunday — generator silently
    /// declines to write.
    func testRunIfDueReturnsNilOnNonSunday() async {
        let calendar = gregorian()
        let monday = makeDate(year: 2026, month: 5, day: 4, hour: 19, calendar: calendar)
        let result = await generator.runIfDue(in: circle.id!, now: monday, calendar: calendar)
        XCTAssertNil(result)
    }

    /// On Sunday after 6pm, `runIfDue` returns the deterministic
    /// alert id keyed on the circle and the day-of-Sunday. Subsequent
    /// runs return the same id.
    func testRunIfDueProducesDeterministicAlertID() async {
        let calendar = gregorian()
        let sundayDinner = makeDate(year: 2026, month: 5, day: 3, hour: 19, calendar: calendar)

        let first = await generator.runIfDue(in: circle.id!, now: sundayDinner, calendar: calendar)
        XCTAssertNotNil(first)

        let second = await generator.runIfDue(in: circle.id!, now: sundayDinner, calendar: calendar)
        XCTAssertEqual(first, second,
                       "two runs on the same Sunday must produce the same alert id")

        let expected = AlertID.weeklySummary(
            circleID: circle.id!,
            weekEndingSunday: calendar.startOfDay(for: sundayDinner),
            calendar: calendar
        )
        XCTAssertEqual(first, expected)
    }

    // MARK: - Stats

    /// `encodeStats` produces a Firestore-friendly map with one entry
    /// per person plus a `_summary` row aggregating across the circle.
    func testEncodeStatsAggregates() {
        let pid = UUID()
        let stats = [
            WeeklySummaryGenerator.PersonStats(
                personID: pid, personName: "Grandpa", taken: 19, scheduled: 21
            )
        ]
        let map = WeeklySummaryGenerator.encodeStats(stats)
        XCTAssertEqual(map[pid.uuidString], "Grandpa|19|21")
        XCTAssertEqual(map["_summary"], "19|21")
    }

    /// Per-person `percent` rounds to nearest int. 19/21 = 90.476…
    /// rounds to 90.
    func testPersonStatsPercentRounding() {
        let stats = WeeklySummaryGenerator.PersonStats(
            personID: UUID(), personName: "x", taken: 19, scheduled: 21
        )
        XCTAssertEqual(stats.percent, 90)

        let perfect = WeeklySummaryGenerator.PersonStats(
            personID: UUID(), personName: "x", taken: 7, scheduled: 7
        )
        XCTAssertEqual(perfect.percent, 100)

        let zero = WeeklySummaryGenerator.PersonStats(
            personID: UUID(), personName: "x", taken: 0, scheduled: 0
        )
        XCTAssertEqual(zero.percent, 100,
                       "no scheduled doses → vacuously perfect, not a div-by-zero")
    }

    // MARK: - Helpers

    /// A gregorian calendar pinned to an explicit zone (the client's
    /// real one — Vancouver). Used for both date construction and gate
    /// evaluation so the two never disagree, which is exactly the bug
    /// the prior `TimeZone.current` evaluation against UTC-built dates
    /// introduced.
    private func gregorian(in timeZone: TimeZone = TimeZone(identifier: "America/Vancouver")!) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Builds the date in the SAME zone the gate will read it in
    /// (`calendar.timeZone`), so "Sunday 6pm" means 6pm in that zone
    /// regardless of where the test runs.
    private func makeDate(year: Int, month: Int, day: Int,
                          hour: Int, minute: Int = 0,
                          calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }
}
