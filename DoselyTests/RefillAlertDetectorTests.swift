import CoreData
import XCTest
@testable import Dosely

/// Covers `RefillAlertDetector`'s selection logic via the deterministic alert
/// ids it returns from `run` — the same testable seam `MissedDoseDetectorTests`
/// uses, so no live Firestore is needed (the no-op service swallows the create).
final class RefillAlertDetectorTests: XCTestCase {
    private var stack: CoreDataStack!
    private var personRepo: PersonRepository!
    private var careCircleRepo: CareCircleRepository!
    private var medRepo: MedicationRepository!
    private var alertsRepo: AlertsRepository!
    private var detector: RefillAlertDetector!
    private var circle: CareCircle!
    private var supervisor: Person!
    private var grandpa: Person!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        let noFirestore = FirestoreService()
        personRepo = PersonRepository(stack: stack, firestore: noFirestore)
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        medRepo = MedicationRepository(stack: stack, firestore: noFirestore)
        alertsRepo = AlertsRepository(stack: stack, firestore: noFirestore)
        detector = RefillAlertDetector(stack: stack, alertsRepo: alertsRepo)
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
        stack = nil; personRepo = nil; careCircleRepo = nil; medRepo = nil
        alertsRepo = nil; detector = nil; circle = nil; supervisor = nil; grandpa = nil
        super.tearDown()
    }

    @discardableResult
    private func seedMed(supply: Int16, daysOfWeek: Int16 = 127,
                         name: String = "Lipitor") async throws -> Medication {
        try await medRepo.saveMedication(
            personID: grandpa.id!, actorPersonID: supervisor.id!,
            name: name, dose: "10mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: supply, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: daysOfWeek)]
        )
    }

    func test_generatesAlertWhenSupplyIsLow() async throws {
        let med = try await seedMed(supply: 5)   // once-daily → 5 days < 7
        let now = Date()
        let attempted = await detector.run(in: circle.id!, now: now)
        XCTAssertEqual(attempted, [AlertID.refill(medicationID: med.id!, date: now)])
    }

    func test_noAlertWhenSupplyAboveThreshold() async throws {
        _ = try await seedMed(supply: 30)   // 30 days, well above the 7-day floor
        let attempted = await detector.run(in: circle.id!, now: Date())
        XCTAssertTrue(attempted.isEmpty)
    }

    func test_skipsAsNeededMedication() async throws {
        // No schedule → indeterminate rate → never "low", even empty.
        _ = try await medRepo.saveMedication(
            personID: grandpa.id!, actorPersonID: supervisor.id!,
            name: "PRN", dose: "5mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 0, pillPhotoData: nil, schedules: []
        )
        let attempted = await detector.run(in: circle.id!, now: Date())
        XCTAssertTrue(attempted.isEmpty)
    }

    func test_deterministicAlertIDPerMedicationAndDay() async throws {
        let med = try await seedMed(supply: 3)
        let now = Date()
        let attempted = await detector.run(in: circle.id!, now: now)
        XCTAssertEqual(attempted.first, AlertID.refill(medicationID: med.id!, date: now))
    }

    func test_skipsWhenUnacknowledgedRefillAlertAlreadyExists() async throws {
        let med = try await seedMed(supply: 4)
        let now = Date()
        let medID = med.id!
        let grandpaID = grandpa.id!
        let circleID = circle.id!
        let alertID = AlertID.refill(medicationID: medID, date: now)

        // Seed a pending (unacknowledged) refill alert for this med directly.
        await stack.viewContext.perform { [stack] in
            let alert = FirestoreModels.FAlert(
                id: alertID, type: FirestoreModels.AlertType.refill,
                personID: grandpaID.uuidString, medicationID: medID.uuidString,
                scheduledTime: nil, createdAt: now, payload: nil,
                acknowledgedBy: nil, acknowledgedByName: nil,
                acknowledgedAt: nil, lastModified: nil
            )
            _ = alert.upsert(in: stack!.viewContext, careCircleID: circleID)
            try? stack!.viewContext.save()
        }

        let attempted = await detector.run(in: circleID, now: now)
        XCTAssertTrue(attempted.isEmpty,
                      "a med with a pending refill alert must not generate another")
    }
}
