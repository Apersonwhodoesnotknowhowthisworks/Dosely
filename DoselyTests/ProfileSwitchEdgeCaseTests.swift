import CoreData
import XCTest
@testable import Dosely

/// The act-as edge cases from Part 9: a live act-as session must drop its
/// lens when the world changes underneath it — the target deleted by
/// another supervisor (9a), the actor demoted out of the supervisor tier
/// (9b), or the session ending (9d). All three land as Core Data mutations
/// or explicit calls; the coordinator's `ObjectsDidChange` observer (the
/// May 28 / June 7 / June 8 reactivity pattern) is what makes 9a/9b fire
/// without anyone re-resolving identity by hand.
@MainActor
final class ProfileSwitchEdgeCaseTests: XCTestCase {

    var stack: CoreDataStack!
    var defaults: UserDefaults!
    var suiteName: String!
    var circle: CareCircle!
    var supervisor: Person!
    var client: Person!
    var coordinator: ProfileSwitchCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        suiteName = "profileswitch-edge-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)

        circle = CareCircle(context: stack.viewContext)
        circle.id = UUID()
        circle.name = "Test Family"
        circle.joinCode = "123456"
        circle.createdAt = Date()

        supervisor = Person(context: stack.viewContext)
        supervisor.id = UUID()
        supervisor.name = "Supervisor"
        supervisor.role = Roles.primarySupervisor
        supervisor.languagePreference = "en"
        supervisor.careCircle = circle
        circle.primarySupervisorPersonID = supervisor.id

        client = Person(context: stack.viewContext)
        client.id = UUID()
        client.name = "Grandpa"
        client.role = Roles.managedClient
        client.languagePreference = "en"
        client.careCircle = circle
        try stack.viewContext.save()

        coordinator = ProfileSwitchCoordinator(stack: stack, defaults: defaults)
        coordinator.currentPersonProvider = { [weak self] in self?.supervisor }
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        coordinator = nil
        stack = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Poll a predicate against the main actor — same helper shape as
    /// CircleSettingsViewModelTests / PeopleManagementViewModelTests.
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

    func test_actorPersonAutoClearsWhenTargetDeleted() async throws {
        try coordinator.actAs(personID: client.id!)
        XCTAssertEqual(coordinator.actingPersonID, client.id)

        // Another supervisor removes the target; the SyncCoordinator mirror
        // hard-deletes the local row. Same shape here: delete + save on the
        // view context, which fires the coordinator's observer.
        stack.viewContext.delete(client)
        try stack.viewContext.save()

        await awaitValue("act-as clears when the target is deleted") { [weak self] in
            self?.coordinator.actingPersonID == nil
        }
        XCTAssertNil(coordinator.actingPersonID)
        // The lens fell back to the supervisor's own identity.
        XCTAssertEqual(coordinator.actorPerson?.id, supervisor.id)
        XCTAssertNil(defaults.string(forKey: ProfileSwitchCoordinator.defaultsKey))
    }

    func test_actorPersonAutoClearsWhenSupervisorDemoted() async throws {
        try coordinator.actAs(personID: client.id!)
        XCTAssertEqual(coordinator.actingPersonID, client.id)

        // Another primary demotes this supervisor to managed_client
        // mid-act-as (9b): the role mutates in place on the live row — no
        // reassignment of any @Published, exactly the trap the observer
        // exists for.
        supervisor.role = Roles.managedClient
        circle.primarySupervisorPersonID = UUID()
        try stack.viewContext.save()

        await awaitValue("act-as clears when the actor loses supervisor role") { [weak self] in
            self?.coordinator.actingPersonID == nil
        }
        XCTAssertNil(coordinator.actingPersonID)
        XCTAssertNil(defaults.string(forKey: ProfileSwitchCoordinator.defaultsKey))
    }

    func test_actorPersonAutoClearsWhenPrimaryDemotedToSecondary() async throws {
        try coordinator.actAs(personID: client.id!)
        XCTAssertEqual(coordinator.actingPersonID, client.id)

        // The promotion handoff shape: this primary runs promoteToPrimary
        // from another device; the batch demotes them to SECONDARY and moves
        // primarySupervisorPersonID. A secondary may not hold a lens they
        // could never start (entry requires primary), and their dose taps
        // would silently no-op — revalidate must use the same isPrimary
        // predicate as the entry validation, not the looser isAnySupervisor.
        supervisor.role = Roles.secondarySupervisor
        circle.primarySupervisorPersonID = UUID()
        try stack.viewContext.save()

        await awaitValue("act-as clears when the actor is demoted to secondary") { [weak self] in
            self?.coordinator.actingPersonID == nil
        }
        XCTAssertNil(coordinator.actingPersonID)
        XCTAssertNil(defaults.string(forKey: ProfileSwitchCoordinator.defaultsKey))
    }

    func test_signOut_clearsActingPersonID() throws {
        try coordinator.actAs(personID: client.id!)
        XCTAssertEqual(coordinator.actingPersonID, client.id)

        coordinator.clearOnSignOut()

        XCTAssertNil(coordinator.actingPersonID)
        XCTAssertNil(defaults.string(forKey: ProfileSwitchCoordinator.defaultsKey),
                     "the next sign-in must not inherit a previous session's act-as state")
    }
}
