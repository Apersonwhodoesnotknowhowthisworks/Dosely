import CoreData
import XCTest
@testable import Dosely

final class CareCircleMigrationTests: XCTestCase {
    var stack: CoreDataStack!
    var noFirestore: FirestoreService!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        // Explicit no-op service — without this, the migration's repos
        // would default to `FirestoreService.shared` and the first
        // Firestore write would "start" the SDK singleton, blocking
        // FirestoreServiceTests from setting emulator settings later.
        noFirestore = FirestoreService()
        CareCircleMigration.resetForTesting()
    }

    override func tearDown() {
        stack = nil
        CareCircleMigration.resetForTesting()
        super.tearDown()
    }

    func testMigrationReturnsNilForBrandNewAccountWithNoOrphans() async {
        // Brand-new account on a clean install has no orphan rows. The
        // migration must return nil so AuthGate routes the user to
        // CircleSetupView instead of auto-bootstrapping a circle.
        let supervisor = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-1", displayName: "Joe",
            languagePreference: "en", stack: stack, firestore: noFirestore
        )
        XCTAssertNil(supervisor)
        XCTAssertFalse(CareCircleMigration.isComplete,
                       "flag must stay unset so a later sign-in can still migrate orphans")
    }

    func testMigrationAutoBootstrapsWhenLegacyOrphansExist() async throws {
        // Pre-Prompt-13 orphan: a Medication without personID.
        let context = stack.viewContext
        let med = Medication(context: context)
        med.id = UUID()
        med.name = "Legacy"
        med.dose = "10mg"
        med.dateAdded = Date()
        try context.save()

        let supervisor = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-legacy", displayName: "Joe",
            languagePreference: "en", stack: stack, firestore: noFirestore
        )
        XCTAssertNotNil(supervisor)
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
            languagePreference: "en", stack: stack, firestore: noFirestore
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

    func testMigrationIsIdempotentForLegacyData() async throws {
        // Seed orphan data so the first call triggers auto-bootstrap.
        let context = stack.viewContext
        let med = Medication(context: context)
        med.id = UUID()
        med.name = "Legacy"
        med.dose = "10mg"
        med.dateAdded = Date()
        try context.save()

        _ = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-3", displayName: "X",
            languagePreference: "en", stack: stack, firestore: noFirestore
        )
        XCTAssertTrue(CareCircleMigration.isComplete)

        // Calling again returns the existing supervisor without creating a
        // new circle.
        let again = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-3", displayName: "X",
            languagePreference: "en", stack: stack, firestore: noFirestore
        )
        XCTAssertNotNil(again)

        let circleRequest = NSFetchRequest<CareCircle>(entityName: "CareCircle")
        let circles = (try? stack.viewContext.fetch(circleRequest)) ?? []
        XCTAssertEqual(circles.count, 1)
    }

    func testMigrationFindsExistingSupervisorEvenWithoutOrphans() async {
        // Simulate a user who completed CircleSetupView (Person row already
        // exists) but the migration flag hasn't been set yet (e.g. they
        // signed up on a build with no orphan data anywhere). Migration
        // should find them and set the flag, no extra circles.
        let careRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        _ = await careRepo.createCareCircle(
            name: "Existing", foundingSupervisorFirebaseUID: "fb-existing",
            founderName: "User"
        )

        let supervisor = await CareCircleMigration.runIfNeeded(
            firebaseUID: "fb-existing", displayName: "User",
            languagePreference: "en", stack: stack, firestore: noFirestore
        )
        XCTAssertNotNil(supervisor)
        XCTAssertEqual(supervisor?.careCircle?.name, "Existing")
        XCTAssertTrue(CareCircleMigration.isComplete)
    }
}
