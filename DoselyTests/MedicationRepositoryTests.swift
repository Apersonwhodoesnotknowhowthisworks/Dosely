import CoreData
import XCTest
@testable import Dosely

final class MedicationRepositoryTests: XCTestCase {
    var stack: CoreDataStack!
    var repo: MedicationRepository!
    var personRepo: PersonRepository!
    var careCircleRepo: CareCircleRepository!
    var supervisor: Person!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        repo = MedicationRepository(stack: stack)
        personRepo = PersonRepository(stack: stack)
        careCircleRepo = CareCircleRepository(stack: stack)

        let circle = await careCircleRepo.createCareCircle(
            name: "Test Family",
            foundingSupervisorFirebaseUID: "fb-test-uid",
            founderName: "Tester"
        )
        supervisor = await personRepo.fetchSupervisor(firebaseUID: "fb-test-uid")
        _ = circle
    }

    override func tearDown() {
        repo = nil
        personRepo = nil
        careCircleRepo = nil
        supervisor = nil
        stack = nil
        super.tearDown()
    }

    private var personID: UUID { supervisor.id! }

    // MARK: - saveMedication / fetchMedication / fetchAllMedications

    func testSaveCreatesMedication() async throws {
        let med = try await repo.saveMedication(
            personID: personID,
            actorPersonID: personID,
            name: "Lisinopril",
            dose: "10mg",
            pillsPerDose: 1,
            foodRule: "either",
            notes: nil,
            currentSupply: 30,
            pillPhotoData: nil
        )
        XCTAssertEqual(med.name, "Lisinopril")
        XCTAssertEqual(med.dose, "10mg")
        XCTAssertEqual(med.pillsPerDose, 1)
        XCTAssertEqual(med.currentSupply, 30)
        XCTAssertEqual(med.personID, personID)
        XCTAssertNotNil(med.id)
        XCTAssertNotNil(med.dateAdded)
    }

    func testSaveUpdatesExistingMedication() async throws {
        let created = try await repo.saveMedication(
            personID: personID, actorPersonID: personID,
            name: "Metformin", dose: "500mg", pillsPerDose: 1,
            foodRule: "with", notes: nil, currentSupply: 60, pillPhotoData: nil
        )
        let id = created.id!
        let updated = try await repo.saveMedication(
            personID: personID, actorPersonID: personID,
            id: id, name: "Metformin", dose: "1000mg", pillsPerDose: 2,
            foodRule: "with", notes: "Twice daily", currentSupply: 45, pillPhotoData: nil
        )
        XCTAssertEqual(updated.id, id)
        XCTAssertEqual(updated.dose, "1000mg")
        XCTAssertEqual(updated.pillsPerDose, 2)
        XCTAssertEqual(updated.notes, "Twice daily")
        let all = await repo.fetchAllMedications(for: personID)
        XCTAssertEqual(all.count, 1)
    }

    func testFetchMedicationByID() async throws {
        let saved = try await repo.saveMedication(
            personID: personID, actorPersonID: personID,
            name: "Atorvastatin", dose: "20mg", pillsPerDose: 1,
            foodRule: "either", notes: nil, currentSupply: 30, pillPhotoData: nil
        )
        let fetched = await repo.fetchMedication(id: saved.id!)
        XCTAssertEqual(fetched?.name, "Atorvastatin")
    }

    func testFetchMedicationByIDReturnsNilWhenMissing() async {
        let fetched = await repo.fetchMedication(id: UUID())
        XCTAssertNil(fetched)
    }

    func testFetchAllMedicationsScopedByPerson() async throws {
        // Add two meds for the supervisor
        _ = try await repo.saveMedication(personID: personID, actorPersonID: personID,
                                          name: "A", dose: "1mg", pillsPerDose: 1,
                                          foodRule: "either", notes: nil,
                                          currentSupply: 1, pillPhotoData: nil)
        _ = try await repo.saveMedication(personID: personID, actorPersonID: personID,
                                          name: "B", dose: "1mg", pillsPerDose: 1,
                                          foodRule: "either", notes: nil,
                                          currentSupply: 1, pillPhotoData: nil)
        // Add a managed-client Person and one med for them
        let circle = supervisor.careCircle!
        let client = await personRepo.createManagedClient(name: "Grandma",
                                                          photoData: nil,
                                                          language: "pa",
                                                          in: circle)
        _ = try await repo.saveMedication(personID: client.id!, actorPersonID: personID,
                                          name: "C", dose: "1mg", pillsPerDose: 1,
                                          foodRule: "either", notes: nil,
                                          currentSupply: 1, pillPhotoData: nil)

        let supervisorMeds = await repo.fetchAllMedications(for: personID)
        XCTAssertEqual(supervisorMeds.count, 2)

        let clientMeds = await repo.fetchAllMedications(for: client.id!)
        XCTAssertEqual(clientMeds.count, 1)
        XCTAssertEqual(clientMeds.first?.name, "C")
    }

    // MARK: - permissions

    func testClientCannotSaveMedication() async {
        let circle = supervisor.careCircle!
        let client = await personRepo.createDeviceClient(
            name: "Bibi", photoData: nil, pinPlaintext: "1234",
            language: "pa", in: circle
        )
        do {
            _ = try await repo.saveMedication(
                personID: client.id!,
                actorPersonID: client.id!,
                name: "Aspirin", dose: "81mg", pillsPerDose: 1, foodRule: "with",
                notes: nil, currentSupply: 30, pillPhotoData: nil
            )
            XCTFail("Expected permissionDenied")
        } catch let error as MedicationRepositoryError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testManagedClientCannotSaveMedication() async {
        let circle = supervisor.careCircle!
        let client = await personRepo.createManagedClient(
            name: "Grandma", photoData: nil, language: "pa", in: circle
        )
        do {
            _ = try await repo.saveMedication(
                personID: client.id!,
                actorPersonID: client.id!,
                name: "Anything", dose: "10mg", pillsPerDose: 1, foodRule: "either",
                notes: nil, currentSupply: 10, pillPhotoData: nil
            )
            XCTFail("Expected permissionDenied")
        } catch let error as MedicationRepositoryError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - deleteMedication

    func testDeleteRemovesMedicationAndCascades() async throws {
        let med = try await repo.saveMedication(
            personID: personID, actorPersonID: personID,
            name: "Aspirin", dose: "81mg", pillsPerDose: 1, foodRule: "with",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)]
        )
        let id = med.id!
        _ = await repo.logDose(medicationID: id, scheduledTime: Date(),
                               actualTime: Date(), status: "taken",
                               loggedByPersonID: personID)

        try await repo.deleteMedication(id: id, actorPersonID: personID)

        let fetched = await repo.fetchMedication(id: id)
        XCTAssertNil(fetched)
        let all = await repo.fetchAllMedications(for: personID)
        XCTAssertTrue(all.isEmpty)

        let scheduleRequest = NSFetchRequest<DoseSchedule>(entityName: "DoseSchedule")
        let logRequest = NSFetchRequest<DoseLog>(entityName: "DoseLog")
        let schedules = try? stack.viewContext.fetch(scheduleRequest)
        let logs = try? stack.viewContext.fetch(logRequest)
        XCTAssertEqual(schedules?.count, 0)
        XCTAssertEqual(logs?.count, 0)
    }

    // MARK: - logDose / fetchDoseLogs

    func testLogDoseCreatesLogWithLoggedByPersonID() async throws {
        let med = try await repo.saveMedication(
            personID: personID, actorPersonID: personID,
            name: "Ibuprofen", dose: "200mg", pillsPerDose: 1, foodRule: "with",
            notes: nil, currentSupply: 30, pillPhotoData: nil
        )
        let scheduled = Date()
        let log = await repo.logDose(medicationID: med.id!, scheduledTime: scheduled,
                                     actualTime: scheduled, status: "taken",
                                     loggedByPersonID: personID)
        XCTAssertNotNil(log)
        XCTAssertEqual(log?.status, "taken")
        XCTAssertEqual(log?.medication?.id, med.id)
        XCTAssertEqual(log?.loggedByPersonID, personID)
    }

    func testLogDoseReturnsNilForUnknownMedication() async {
        let log = await repo.logDose(medicationID: UUID(), scheduledTime: Date(),
                                     actualTime: nil, status: "missed",
                                     loggedByPersonID: personID)
        XCTAssertNil(log)
    }

    func testFetchDoseLogsScopedToPerson() async throws {
        let medA = try await repo.saveMedication(personID: personID, actorPersonID: personID,
                                                 name: "A", dose: "1mg", pillsPerDose: 1,
                                                 foodRule: "either", notes: nil,
                                                 currentSupply: 1, pillPhotoData: nil)
        let medB = try await repo.saveMedication(personID: personID, actorPersonID: personID,
                                                 name: "B", dose: "1mg", pillsPerDose: 1,
                                                 foodRule: "either", notes: nil,
                                                 currentSupply: 1, pillPhotoData: nil)

        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        let tomorrow = now.addingTimeInterval(86_400)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)

        _ = await repo.logDose(medicationID: medA.id!, scheduledTime: now, actualTime: now,
                               status: "taken", loggedByPersonID: personID)
        _ = await repo.logDose(medicationID: medA.id!, scheduledTime: twoDaysAgo,
                               actualTime: nil, status: "missed", loggedByPersonID: personID)
        _ = await repo.logDose(medicationID: medB.id!, scheduledTime: now, actualTime: now,
                               status: "taken", loggedByPersonID: personID)

        let windowed = await repo.fetchDoseLogs(for: nil, personID: personID,
                                                from: yesterday, to: tomorrow)
        XCTAssertEqual(windowed.count, 2)

        let medAOnly = await repo.fetchDoseLogs(for: medA.id!, personID: personID,
                                                from: yesterday, to: tomorrow)
        XCTAssertEqual(medAOnly.count, 1)
        XCTAssertEqual(medAOnly.first?.medication?.id, medA.id)
    }

    // MARK: - fetchScheduledDoses

    func testFetchScheduledDosesReturnsMedsForWeekday() async throws {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 20; comps.hour = 12
        let monday = Calendar.current.date(from: comps)!
        let tuesday = Calendar.current.date(byAdding: .day, value: 1, to: monday)!

        _ = try await repo.saveMedication(
            personID: personID, actorPersonID: personID,
            name: "DailyMed", dose: "1mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)]
        )
        _ = try await repo.saveMedication(
            personID: personID, actorPersonID: personID,
            name: "MondayOnly", dose: "1mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "09:00", daysOfWeek: 1)]
        )
        _ = try await repo.saveMedication(
            personID: personID, actorPersonID: personID,
            name: "WeekendOnly", dose: "1mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "10:00", daysOfWeek: 32 | 64)]
        )

        let mondayDoses = await repo.fetchScheduledDoses(for: personID, on: monday)
        let mondayNames = Set(mondayDoses.map { $0.0.name })
        XCTAssertEqual(mondayNames, Set(["DailyMed", "MondayOnly"]))

        let tuesdayDoses = await repo.fetchScheduledDoses(for: personID, on: tuesday)
        let tuesdayNames = Set(tuesdayDoses.map { $0.0.name })
        XCTAssertEqual(tuesdayNames, Set(["DailyMed"]))
    }

    func testWeekdayBitmaskMapping() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 20; comps.hour = 12
        let monday = Calendar.current.date(from: comps)!
        XCTAssertEqual(WeekdayBitmask.mask(for: monday), 1)

        let sunday = Calendar.current.date(byAdding: .day, value: -1, to: monday)!
        XCTAssertEqual(WeekdayBitmask.mask(for: sunday), 64)

        let saturday = Calendar.current.date(byAdding: .day, value: 5, to: monday)!
        XCTAssertEqual(WeekdayBitmask.mask(for: saturday), 32)
    }
}
