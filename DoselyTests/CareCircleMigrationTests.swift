import CoreData
import XCTest
@testable import Dosely

final class CareCircleMigrationTests: XCTestCase {
    var stack: CoreDataStack!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        CareCircleMigration.resetForTesting()
    }

    override func tearDown() {
        stack = nil
        CareCircleMigration.resetForTesting()
        super.tearDown()
    }

    func testMigrationCreatesCircleAndSupervisorOnFirstRun() async {
        let supervisor = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-1", displayName: "Joe",
            languagePreference: "en", stack: stack
        )
        XCTAssertNotNil(supervisor)
        XCTAssertEqual(supervisor?.role, "supervisor")
        XCTAssertEqual(supervisor?.firebaseUID, "fb-1")
        XCTAssertEqual(supervisor?.careCircle?.name, "My Family")
        XCTAssertTrue(CareCircleMigration.isComplete)
    }

    func testMigrationReassignsExistingMedicationsAndLogs() async throws {
        // Pre-migration state: a Medication and DoseLog without personID.
        let context = stack.viewContext
        let med = Medication(context: context)
        med.id = UUID()
        med.name = "Legacy Med"
        med.dose = "10mg"
        med.dateAdded = Date()
        let log = DoseLog(context: context)
        log.id = UUID()
        log.scheduledTime = Date()
        log.status = "taken"
        log.medication = med
        try context.save()

        // Run migration
        let supervisor = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-2", displayName: "Mary",
            languagePreference: "en", stack: stack
        )
        XCTAssertNotNil(supervisor)

        // Both rows should now carry the supervisor's id.
        let medRequest = NSFetchRequest<Medication>(entityName: "Medication")
        let allMeds = try context.fetch(medRequest)
        XCTAssertEqual(allMeds.first?.personID, supervisor?.id)

        let logRequest = NSFetchRequest<DoseLog>(entityName: "DoseLog")
        let allLogs = try context.fetch(logRequest)
        XCTAssertEqual(allLogs.first?.loggedByPersonID, supervisor?.id)
    }

    func testMigrationIsIdempotent() async {
        _ = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-3", displayName: "X",
            languagePreference: "en", stack: stack
        )
        XCTAssertTrue(CareCircleMigration.isComplete)

        // Calling again returns the existing supervisor without creating a
        // new circle.
        let again = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-3", displayName: "X",
            languagePreference: "en", stack: stack
        )
        XCTAssertNotNil(again)

        let circleRequest = NSFetchRequest<CareCircle>(entityName: "CareCircle")
        let circles = (try? stack.viewContext.fetch(circleRequest)) ?? []
        XCTAssertEqual(circles.count, 1)
    }
}
