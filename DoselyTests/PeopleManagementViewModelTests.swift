import CoreData
import XCTest
@testable import Dosely

/// Pins the People tab's *parent* reactivity contract. The June 8 fix made the
/// Care circle card observe Core Data, but it also moved the circle-id
/// derivation up to the parent as `if isLoaded, let circleID =
/// authService.currentPerson?.careCircle?.id` — a one-shot snapshot read of an
/// `NSManagedObject` relationship that never re-evaluated when the relationship
/// landed in place, so the whole section (and, through the same nil read in
/// `reload()`, the people list) went missing on a freshly-created account.
/// `PeopleManagementViewModel` re-reads the circle id on every
/// `NSManagedObjectContextObjectsDidChange`; these tests mutate the Person's
/// `careCircle` relationship in place on the view context (the same mechanic as
/// the `CircleSettingsViewModel` and May 28 `SupervisorDashboardViewModel`
/// reactivity tests) and assert the published id follows without a manual
/// reload.
@MainActor
final class PeopleManagementViewModelTests: XCTestCase {
    private var stack: CoreDataStack!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeCircle(name: String = "Test Family") -> CareCircle {
        let circle = CareCircle(context: stack.viewContext)
        circle.id = UUID()
        circle.name = name
        circle.joinCode = "482913"
        circle.createdAt = Date()
        return circle
    }

    private func makePerson(in circle: CareCircle?) -> Person {
        let person = Person(context: stack.viewContext)
        person.id = UUID()
        person.name = "Grandfather"
        person.role = Roles.primarySupervisor
        person.careCircle = circle
        return person
    }

    /// Poll the @Published value briefly: the Core Data save fires the
    /// notification synchronously, the observer schedules a Task on @MainActor,
    /// and we need that task to land before asserting (mirrors the June 8 test).
    private func awaitValue(_ description: String, _ predicate: @escaping () -> Bool) async {
        let expectation = expectation(description: description)
        Task { @MainActor in
            for _ in 0..<20 {
                if predicate() { expectation.fulfill(); return }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Tests

    func test_init_loadsInitialCareCircleID() throws {
        let circle = makeCircle()
        let person = makePerson(in: circle)
        try stack.viewContext.save()

        let vm = PeopleManagementViewModel(stack: stack, person: person)
        XCTAssertEqual(vm.careCircleID, circle.id,
                       "the view model must read the bound person's careCircle id on init")
    }

    func test_careCircleID_isNil_whenPersonHasNoCircle() throws {
        let person = makePerson(in: nil)
        try stack.viewContext.save()

        let vm = PeopleManagementViewModel(stack: stack, person: person)
        XCTAssertNil(vm.careCircleID,
                     "no relationship yet → nil id → the parent shows the setting-up placeholder, not a card")
    }

    func test_careCircleIDUpdatesWhenRelationshipEstablishedInCoreData() async throws {
        let circle = makeCircle()
        let person = makePerson(in: nil)
        try stack.viewContext.save()

        let vm = PeopleManagementViewModel(stack: stack, person: person)
        XCTAssertNil(vm.careCircleID)

        await stack.viewContext.perform { [self] in
            person.careCircle = circle
            try? stack.viewContext.save()
        }

        await awaitValue("careCircleID follows the in-place relationship write") {
            vm.careCircleID == circle.id
        }
        XCTAssertEqual(vm.careCircleID, circle.id,
                       "careCircleID must follow an in-place Person.careCircle mutation without a manual reload")
    }

    func test_careCircleIDClears_whenRelationshipRemovedInCoreData() async throws {
        let circle = makeCircle()
        let person = makePerson(in: circle)
        try stack.viewContext.save()

        let vm = PeopleManagementViewModel(stack: stack, person: person)
        XCTAssertEqual(vm.careCircleID, circle.id)

        await stack.viewContext.perform { [self] in
            person.careCircle = nil
            try? stack.viewContext.save()
        }

        await awaitValue("careCircleID clears when the relationship is removed") {
            vm.careCircleID == nil
        }
        XCTAssertNil(vm.careCircleID)
    }

    func test_bind_updatesCareCircleID_whenPersonSuppliedAfterInit() throws {
        let circle = makeCircle()
        let person = makePerson(in: circle)
        try stack.viewContext.save()

        // Mirrors the view: the @StateObject is built with no person (the
        // @EnvironmentObject authService isn't available at init), then bound
        // from `.task` once the environment is live.
        let vm = PeopleManagementViewModel(stack: stack)
        XCTAssertNil(vm.careCircleID)

        vm.bind(person: person)
        XCTAssertEqual(vm.careCircleID, circle.id,
                       "bind(person:) reads the careCircle id synchronously")
    }

    func test_observerRemovedOnDeinit() async throws {
        let circle = makeCircle()
        let person = makePerson(in: nil)
        try stack.viewContext.save()

        weak var weakVM: PeopleManagementViewModel?
        do {
            let vm = PeopleManagementViewModel(stack: stack, person: person)
            weakVM = vm
            XCTAssertNotNil(weakVM)
        }
        // The [weak self] observer must not retain the view model.
        XCTAssertNil(weakVM, "the view model must deallocate; the observer must not create a retain cycle")

        // A mutation after deallocation must not crash (the observer is gone).
        await stack.viewContext.perform { [self] in
            person.careCircle = circle
            try? stack.viewContext.save()
        }
    }
}
