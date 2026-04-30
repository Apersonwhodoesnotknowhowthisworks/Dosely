import CoreData
import XCTest
@testable import Dosely

final class PrimaryRoleMigrationTests: XCTestCase {
    var stack: CoreDataStack!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        PrimaryRoleMigration.resetForTesting()
    }

    override func tearDown() {
        stack = nil
        PrimaryRoleMigration.resetForTesting()
        super.tearDown()
    }

    // MARK: - No-op paths

    func testMigrationIsNoOpOnFreshInstall() async {
        // No CareCircles in the store. Migration flips the flag and
        // doesn't touch Firestore.
        let didApply = await PrimaryRoleMigration.runIfNeeded(
            stack: stack, firestore: FirestoreService()
        )
        XCTAssertFalse(didApply)
        XCTAssertTrue(PrimaryRoleMigration.isComplete)
    }

    func testMigrationIsNoOpOnAlreadyStampedCircle() async {
        // CareCircle already has primarySupervisorPersonID — nothing to do.
        let context = stack.viewContext
        await context.perform { [self] in
            let circle = CareCircle(context: stack.viewContext)
            circle.id = UUID()
            circle.name = "Test"
            circle.joinCode = "111111"
            circle.createdAt = Date()
            circle.primarySupervisorPersonID = UUID()

            let p = Person(context: stack.viewContext)
            p.id = UUID()
            p.name = "Already Primary"
            p.role = Roles.primarySupervisor
            p.languagePreference = "en"
            p.firebaseUID = "uid-1"
            p.failedPinAttempts = 0
            p.careCircle = circle
            try? stack.viewContext.save()
        }
        let didApply = await PrimaryRoleMigration.runIfNeeded(
            stack: stack, firestore: FirestoreService()
        )
        XCTAssertFalse(didApply)
        XCTAssertTrue(PrimaryRoleMigration.isComplete)
    }

    // MARK: - Single-supervisor circle

    func testSingleLegacySupervisorBecomesPrimary() async {
        let context = stack.viewContext
        let supervisorID = UUID()
        let circleID = UUID()
        await context.perform { [self] in
            let circle = CareCircle(context: stack.viewContext)
            circle.id = circleID
            circle.name = "Solo"
            circle.joinCode = "222222"
            circle.createdAt = Date()
            // primarySupervisorPersonID intentionally nil — pre-migration state.

            let p = Person(context: stack.viewContext)
            p.id = supervisorID
            p.name = "Founder"
            p.role = Roles.legacySupervisor
            p.languagePreference = "en"
            p.firebaseUID = "uid-founder"
            p.failedPinAttempts = 0
            p.careCircle = circle
            try? stack.viewContext.save()
        }

        // Use a no-op FirestoreService (db == nil) so the migration runs
        // its Core Data mirror without trying to hit Firestore.
        let didApply = await PrimaryRoleMigration.runIfNeeded(
            stack: stack, firestore: FirestoreService()
        )
        XCTAssertTrue(didApply)
        XCTAssertTrue(PrimaryRoleMigration.isComplete)

        await context.perform { [self] in
            let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
            request.predicate = NSPredicate(format: "id == %@", circleID as CVarArg)
            let circle = (try? stack.viewContext.fetch(request))?.first
            XCTAssertEqual(circle?.primarySupervisorPersonID, supervisorID)

            let pRequest = NSFetchRequest<Person>(entityName: "Person")
            pRequest.predicate = NSPredicate(format: "id == %@", supervisorID as CVarArg)
            let person = (try? stack.viewContext.fetch(pRequest))?.first
            XCTAssertEqual(person?.role, Roles.primarySupervisor)
        }
    }

    // MARK: - Multi-supervisor circle (deterministic primary selection)

    func testMultiSupervisorCirclePicksLowestUUIDAsPrimary() async {
        let context = stack.viewContext
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let circleID = UUID()
        await context.perform { [self] in
            let circle = CareCircle(context: stack.viewContext)
            circle.id = circleID
            circle.name = "Multi"
            circle.joinCode = "333333"
            circle.createdAt = Date()

            let aunt1 = Person(context: stack.viewContext)
            aunt1.id = lowID
            aunt1.name = "Aunt 1"
            aunt1.role = Roles.legacySupervisor
            aunt1.languagePreference = "en"
            aunt1.firebaseUID = "uid-1"
            aunt1.failedPinAttempts = 0
            aunt1.careCircle = circle

            let aunt2 = Person(context: stack.viewContext)
            aunt2.id = highID
            aunt2.name = "Aunt 2"
            aunt2.role = Roles.legacySupervisor
            aunt2.languagePreference = "en"
            aunt2.firebaseUID = "uid-2"
            aunt2.failedPinAttempts = 0
            aunt2.careCircle = circle
            try? stack.viewContext.save()
        }

        let didApply = await PrimaryRoleMigration.runIfNeeded(
            stack: stack, firestore: FirestoreService()
        )
        XCTAssertTrue(didApply)

        await context.perform { [self] in
            let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
            request.predicate = NSPredicate(format: "id == %@", circleID as CVarArg)
            let circle = (try? stack.viewContext.fetch(request))?.first
            XCTAssertEqual(circle?.primarySupervisorPersonID, lowID,
                           "lowest-UUID supervisor must be selected as primary")

            let pRequest = NSFetchRequest<Person>(entityName: "Person")
            let people = (try? stack.viewContext.fetch(pRequest)) ?? []
            let lowPerson = people.first(where: { $0.id == lowID })
            let highPerson = people.first(where: { $0.id == highID })
            XCTAssertEqual(lowPerson?.role, Roles.primarySupervisor)
            XCTAssertEqual(highPerson?.role, Roles.secondarySupervisor)
        }
    }

    // MARK: - Idempotency

    func testMigrationFlagPreventsRerun() async {
        // First run.
        await PrimaryRoleMigration.runIfNeeded(
            stack: stack, firestore: FirestoreService()
        )
        XCTAssertTrue(PrimaryRoleMigration.isComplete)

        // Add a new "supervisor" row (simulating new data slipping in
        // somehow). The flag is set so the migration shouldn't try to
        // touch it.
        let context = stack.viewContext
        let circleID = UUID()
        let personID = UUID()
        await context.perform { [self] in
            let circle = CareCircle(context: stack.viewContext)
            circle.id = circleID
            circle.name = "Late Add"
            circle.joinCode = "444444"
            circle.createdAt = Date()

            let p = Person(context: stack.viewContext)
            p.id = personID
            p.name = "Late"
            p.role = Roles.legacySupervisor
            p.languagePreference = "en"
            p.firebaseUID = "uid-late"
            p.failedPinAttempts = 0
            p.careCircle = circle
            try? stack.viewContext.save()
        }

        let didApply = await PrimaryRoleMigration.runIfNeeded(
            stack: stack, firestore: FirestoreService()
        )
        XCTAssertFalse(didApply, "migration must not re-run after the flag is set")

        // The legacy row remains untouched — the flag prevented the sweep.
        await context.perform { [self] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(format: "id == %@", personID as CVarArg)
            let p = (try? stack.viewContext.fetch(request))?.first
            XCTAssertEqual(p?.role, Roles.legacySupervisor)
        }
    }
}
