import CoreData
import XCTest
@testable import Dosely

/// Pins the Care circle card's reactivity contract. The June 7 fix bound the
/// card to a `@State` snapshot loaded on a token change; the token only moved
/// when `AuthService.currentPerson` was reassigned, so an in-place mutation of
/// the CareCircle row (the create write, or a listener mirror) left the join
/// code stuck on "Generating code…". `CircleSettingsViewModel` reads through
/// Core Data on every `NSManagedObjectContextObjectsDidChange` — these tests
/// mutate the row in place on the view context (the same mechanic as the
/// May 28 `SupervisorDashboardViewModel` reactivity test) and assert the
/// published values follow without a manual reload.
@MainActor
final class CircleSettingsViewModelTests: XCTestCase {
    private var stack: CoreDataStack!
    private var careCircleRepo: CareCircleRepository!
    private var circle: CareCircle!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        let noFirestore = FirestoreService()
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        circle = await careCircleRepo.createCareCircle(
            name: "Test Family", foundingSupervisorFirebaseUID: "uid-1", founderName: "Founder"
        )
    }

    override func tearDown() {
        stack = nil
        careCircleRepo = nil
        circle = nil
        super.tearDown()
    }

    /// Poll the @Published value briefly: the Core Data save fires the
    /// notification synchronously, the observer schedules a Task on @MainActor,
    /// and we need that task to land before asserting (mirrors the May 28 test).
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

    func test_init_loadsInitialCircleState() {
        let vm = CircleSettingsViewModel(stack: stack, careCircleID: circle.id!)
        XCTAssertEqual(vm.circleName, "Test Family")
        XCTAssertEqual(vm.joinCode, circle.joinCode)
        XCTAssertNotNil(vm.joinCode)
        XCTAssertFalse(vm.joinCode?.isEmpty ?? true, "a created circle has a 6-digit join code")
    }

    func test_joinCodeUpdatesWhenCareCircleMutatesInCoreData() async {
        let vm = CircleSettingsViewModel(stack: stack, careCircleID: circle.id!)
        await stack.viewContext.perform { [self] in
            circle.joinCode = "654321"
            try? stack.viewContext.save()
        }
        await awaitValue("joinCode follows the Core Data mutation") { vm.joinCode == "654321" }
        XCTAssertEqual(vm.joinCode, "654321",
                       "joinCode must follow an in-place CareCircle mutation without a manual reload")
    }

    func test_circleNameUpdatesWhenCareCircleMutatesInCoreData() async {
        let vm = CircleSettingsViewModel(stack: stack, careCircleID: circle.id!)
        await stack.viewContext.perform { [self] in
            circle.name = "Renamed Family"
            try? stack.viewContext.save()
        }
        await awaitValue("circleName follows the Core Data mutation") { vm.circleName == "Renamed Family" }
        XCTAssertEqual(vm.circleName, "Renamed Family")
    }

    func test_emptyCircleName_rendersPlaceholder() {
        let placeholder = "Untitled family"
        XCTAssertEqual(CircleSettingsSection.circleNameDisplayValue("", placeholder: placeholder), placeholder)
        XCTAssertEqual(CircleSettingsSection.circleNameDisplayValue("   ", placeholder: placeholder), placeholder)
        XCTAssertEqual(CircleSettingsSection.circleNameDisplayValue("Smith Family", placeholder: placeholder), "Smith Family")
    }

    func test_observerRemovedOnDeinit() async {
        weak var weakVM: CircleSettingsViewModel?
        do {
            let vm = CircleSettingsViewModel(stack: stack, careCircleID: circle.id!)
            weakVM = vm
            XCTAssertNotNil(weakVM)
        }
        // Out of scope: deinit removes the observer and the view model
        // deallocates — the [weak self] observer must not retain it.
        XCTAssertNil(weakVM, "the view model must deallocate; the observer must not create a retain cycle")
        // A mutation after deallocation must not crash (the observer is gone).
        await stack.viewContext.perform { [self] in
            circle.joinCode = "111111"
            try? stack.viewContext.save()
        }
    }
}
