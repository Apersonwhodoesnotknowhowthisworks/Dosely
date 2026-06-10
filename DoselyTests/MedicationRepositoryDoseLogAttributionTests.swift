import CoreData
import XCTest
@testable import Dosely

/// Pins the D5 dose-log attribution semantics for act-as mode. The
/// repository itself has no act-as concept — the call sites decide the
/// split — so these tests drive the exact shapes TodayView passes:
///
/// - act-as: `loggedByPersonID` = the SUPERVISOR's id (who actually
///   tapped), while the dose's person is the TARGET's (derived from the
///   medication, which belongs to the acting person whose cards are on
///   screen).
/// - outside act-as: unchanged — a client logging their own dose
///   attributes to themselves.
///
/// Template: the own-dose-scoping tests in MedicationRepositoryTests.
final class MedicationRepositoryDoseLogAttributionTests: XCTestCase {

    var stack: CoreDataStack!
    var repo: MedicationRepository!
    var personRepo: PersonRepository!
    var careCircleRepo: CareCircleRepository!
    var supervisor: Person!
    var client: Person!
    var med: Medication!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        // Explicit no-op FirestoreService isolates the test from the shared
        // singleton — see the note in CareCircleRepositoryTests.
        let noFirestore = FirestoreService()
        repo = MedicationRepository(stack: stack, firestore: noFirestore)
        personRepo = PersonRepository(stack: stack, firestore: noFirestore)
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)

        _ = await careCircleRepo.createCareCircle(
            name: "Test Family",
            foundingSupervisorFirebaseUID: "fb-test-uid",
            founderName: "Tester"
        )
        supervisor = await personRepo.fetchSupervisor(firebaseUID: "fb-test-uid")
        client = try await personRepo.createManagedClient(
            name: "Grandpa", photoData: nil, language: "en",
            in: supervisor.careCircle!, actorPersonID: supervisor.id!
        )
        med = try await repo.saveMedication(
            personID: client.id!, actorPersonID: supervisor.id!,
            name: "Lisinopril", dose: "10mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)]
        )
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    private var todayAt8: Date {
        Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    }

    func test_logDose_inActAsMode_attributesLoggedByToSupervisor() async throws {
        // The act-as call-site shape: the supervisor taps Take on the
        // target's dose card, so loggedBy is the supervisor — NOT the
        // acting person. The audit trail records who did the thing.
        let log = await repo.logDose(
            medicationID: med.id!,
            scheduledTime: todayAt8,
            actualTime: Date(),
            status: DoseStatus.taken.rawValue,
            loggedByPersonID: supervisor.id!
        )
        let created = try XCTUnwrap(log)
        XCTAssertEqual(created.loggedByPersonID, supervisor.id)
        XCTAssertNotEqual(created.loggedByPersonID, client.id)
    }

    @MainActor
    func test_logDose_inActAsMode_targetsActingPersonID() async throws {
        // Through TodayViewModel with the exact split TodayView passes in
        // act-as: loggedBy = supervisor, reload scope = the acting person.
        let viewModel = TodayViewModel(repository: repo)
        await viewModel.load(personID: client.id!)
        let dose = try XCTUnwrap(viewModel.doses.first)

        await viewModel.markTaken(dose, loggedByPersonID: supervisor.id!, personID: client.id!)

        // The dose's person is the TARGET (derived from the medication) and
        // the reload shows the log under the acting person's schedule.
        let updated = try XCTUnwrap(viewModel.doses.first)
        let log = try XCTUnwrap(updated.log)
        XCTAssertEqual(log.medication?.personID, client.id)
        XCTAssertEqual(log.loggedByPersonID, supervisor.id)
        XCTAssertEqual(updated.status, .taken)
    }

    func test_doseLogAttribution_splitsLoggedByFromScope() {
        // The call-site decision itself (TodayView.doseLogAttribution),
        // pinned at the layer where the D5 split actually lives: in act-as
        // the two ids differ — loggedBy must be the signed-in supervisor,
        // scope the acting person — and a revert to the pre-change shape
        // (one id for both) fails here.
        let supervisorID = UUID()
        let actingID = UUID()
        let split = TodayView.doseLogAttribution(currentPersonID: supervisorID,
                                                 actorPersonID: actingID)
        XCTAssertEqual(split?.loggedBy, supervisorID)
        XCTAssertEqual(split?.scope, actingID)

        // Outside act-as both ids are the same person — unchanged behavior.
        let same = TodayView.doseLogAttribution(currentPersonID: supervisorID,
                                                actorPersonID: supervisorID)
        XCTAssertEqual(same?.loggedBy, supervisorID)
        XCTAssertEqual(same?.scope, supervisorID)
    }

    func test_doseLogAttribution_nilWhenEitherIdentityMissing() {
        XCTAssertNil(TodayView.doseLogAttribution(currentPersonID: nil, actorPersonID: UUID()))
        XCTAssertNil(TodayView.doseLogAttribution(currentPersonID: UUID(), actorPersonID: nil))
    }

    func test_logDose_outsideActAsMode_unchanged() async throws {
        // No lens: a client logging their own dose attributes to
        // themselves, exactly as before this feature.
        let log = await repo.logDose(
            medicationID: med.id!,
            scheduledTime: todayAt8,
            actualTime: Date(),
            status: DoseStatus.taken.rawValue,
            loggedByPersonID: client.id!
        )
        let created = try XCTUnwrap(log)
        XCTAssertEqual(created.loggedByPersonID, client.id)
        XCTAssertEqual(created.medication?.personID, client.id)
    }
}
