import CoreData
import XCTest
@testable import Dosely

final class MedicationRepositoryTests: XCTestCase {
    var stack: CoreDataStack!
    var repo: MedicationRepository!

    override func setUp() {
        super.setUp()
        stack = CoreDataStack(inMemory: true)
        repo = MedicationRepository(stack: stack)
    }

    override func tearDown() {
        repo = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - saveMedication / fetchMedication / fetchAllMedications

    func testSaveCreatesMedication() async {
        let med = await repo.saveMedication(
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
        XCTAssertNotNil(med.id)
        XCTAssertNotNil(med.dateAdded)
    }

    func testSaveUpdatesExistingMedication() async {
        let created = await repo.saveMedication(
            name: "Metformin", dose: "500mg", pillsPerDose: 1,
            foodRule: "with", notes: nil, currentSupply: 60, pillPhotoData: nil
        )
        let id = created.id!
        let updated = await repo.saveMedication(
            id: id, name: "Metformin", dose: "1000mg", pillsPerDose: 2,
            foodRule: "with", notes: "Twice daily", currentSupply: 45, pillPhotoData: nil
        )
        XCTAssertEqual(updated.id, id)
        XCTAssertEqual(updated.dose, "1000mg")
        XCTAssertEqual(updated.pillsPerDose, 2)
        XCTAssertEqual(updated.notes, "Twice daily")
        let all = await repo.fetchAllMedications()
        XCTAssertEqual(all.count, 1)
    }

    func testFetchMedicationByID() async {
        let saved = await repo.saveMedication(
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

    func testFetchAllMedicationsReturnsAll() async {
        _ = await repo.saveMedication(name: "A", dose: "1mg", pillsPerDose: 1, foodRule: "either", notes: nil, currentSupply: 1, pillPhotoData: nil)
        _ = await repo.saveMedication(name: "B", dose: "1mg", pillsPerDose: 1, foodRule: "either", notes: nil, currentSupply: 1, pillPhotoData: nil)
        let all = await repo.fetchAllMedications()
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - deleteMedication

    func testDeleteRemovesMedicationAndCascades() async {
        let med = await repo.saveMedication(
            name: "Aspirin", dose: "81mg", pillsPerDose: 1, foodRule: "with",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)]
        )
        let id = med.id!
        _ = await repo.logDose(medicationID: id, scheduledTime: Date(), actualTime: Date(), status: "taken")

        await repo.deleteMedication(id: id)

        let fetched = await repo.fetchMedication(id: id)
        XCTAssertNil(fetched)
        let all = await repo.fetchAllMedications()
        XCTAssertTrue(all.isEmpty)

        let scheduleRequest = NSFetchRequest<DoseSchedule>(entityName: "DoseSchedule")
        let logRequest = NSFetchRequest<DoseLog>(entityName: "DoseLog")
        let schedules = try? stack.viewContext.fetch(scheduleRequest)
        let logs = try? stack.viewContext.fetch(logRequest)
        XCTAssertEqual(schedules?.count, 0)
        XCTAssertEqual(logs?.count, 0)
    }

    // MARK: - logDose / fetchDoseLogs

    func testLogDoseCreatesLog() async {
        let med = await repo.saveMedication(
            name: "Ibuprofen", dose: "200mg", pillsPerDose: 1, foodRule: "with",
            notes: nil, currentSupply: 30, pillPhotoData: nil
        )
        let scheduled = Date()
        let log = await repo.logDose(medicationID: med.id!, scheduledTime: scheduled, actualTime: scheduled, status: "taken")
        XCTAssertNotNil(log)
        XCTAssertEqual(log?.status, "taken")
        XCTAssertEqual(log?.medication?.id, med.id)
    }

    func testLogDoseReturnsNilForUnknownMedication() async {
        let log = await repo.logDose(medicationID: UUID(), scheduledTime: Date(), actualTime: nil, status: "missed")
        XCTAssertNil(log)
    }

    func testFetchDoseLogsFiltersByDateAndMedication() async {
        let medA = await repo.saveMedication(name: "A", dose: "1mg", pillsPerDose: 1, foodRule: "either", notes: nil, currentSupply: 1, pillPhotoData: nil)
        let medB = await repo.saveMedication(name: "B", dose: "1mg", pillsPerDose: 1, foodRule: "either", notes: nil, currentSupply: 1, pillPhotoData: nil)

        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        let tomorrow = now.addingTimeInterval(86_400)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)

        _ = await repo.logDose(medicationID: medA.id!, scheduledTime: now,         actualTime: now, status: "taken")
        _ = await repo.logDose(medicationID: medA.id!, scheduledTime: twoDaysAgo,  actualTime: nil, status: "missed")
        _ = await repo.logDose(medicationID: medB.id!, scheduledTime: now,         actualTime: now, status: "taken")

        let windowed = await repo.fetchDoseLogs(for: nil, from: yesterday, to: tomorrow)
        XCTAssertEqual(windowed.count, 2)

        let medAOnly = await repo.fetchDoseLogs(for: medA.id!, from: yesterday, to: tomorrow)
        XCTAssertEqual(medAOnly.count, 1)
        XCTAssertEqual(medAOnly.first?.medication?.id, medA.id)

        let allTime = await repo.fetchDoseLogs(for: medA.id!, from: twoDaysAgo.addingTimeInterval(-1), to: tomorrow)
        XCTAssertEqual(allTime.count, 2)
    }

    // MARK: - fetchScheduledDoses

    func testFetchScheduledDosesReturnsMedsForWeekday() async {
        // Monday reference date: 2026-04-20 (a Monday).
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 20; comps.hour = 12
        let monday = Calendar.current.date(from: comps)!
        let tuesday = Calendar.current.date(byAdding: .day, value: 1, to: monday)!

        _ = await repo.saveMedication(
            name: "DailyMed", dose: "1mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)]
        )
        _ = await repo.saveMedication(
            name: "MondayOnly", dose: "1mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "09:00", daysOfWeek: 1)]
        )
        _ = await repo.saveMedication(
            name: "WeekendOnly", dose: "1mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "10:00", daysOfWeek: 32 | 64)]
        )

        let mondayDoses = await repo.fetchScheduledDoses(on: monday)
        let mondayNames = Set(mondayDoses.map { $0.0.name })
        XCTAssertEqual(mondayNames, Set(["DailyMed", "MondayOnly"]))

        let tuesdayDoses = await repo.fetchScheduledDoses(on: tuesday)
        let tuesdayNames = Set(tuesdayDoses.map { $0.0.name })
        XCTAssertEqual(tuesdayNames, Set(["DailyMed"]))
    }

    func testWeekdayBitmaskMapping() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 20; comps.hour = 12 // Monday
        let monday = Calendar.current.date(from: comps)!
        XCTAssertEqual(WeekdayBitmask.mask(for: monday), 1)

        let sunday = Calendar.current.date(byAdding: .day, value: -1, to: monday)!
        XCTAssertEqual(WeekdayBitmask.mask(for: sunday), 64)

        let saturday = Calendar.current.date(byAdding: .day, value: 5, to: monday)!
        XCTAssertEqual(WeekdayBitmask.mask(for: saturday), 32)
    }
}
