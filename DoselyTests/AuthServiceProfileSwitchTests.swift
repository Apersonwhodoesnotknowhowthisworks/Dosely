import CoreData
import XCTest
@testable import Dosely

/// Coverage for the act-as profile switcher: eligibility preconditions,
/// actor resolution, persistence round-trip, and AuthGate routing.
///
/// Drives `ProfileSwitchCoordinator` (where `AuthService` delegates all
/// act-as state) rather than `AuthService` itself: `AuthService.init`
/// touches live `Auth.auth()` and kicks `resolveCurrentPerson` against
/// production Firestore in the test host (the June 4 test-host note), so the
/// coordinator carries the injected-stack + injected-defaults seam — the
/// same pattern as the view models. Routing is pinned through the pure
/// static `AuthGate.route` per the 2026-05-28 walker-triage convention.
@MainActor
final class AuthServiceProfileSwitchTests: XCTestCase {

    var stack: CoreDataStack!
    var defaults: UserDefaults!
    var suiteName: String!
    var circle: CareCircle!
    var supervisor: Person!
    var client: Person!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        suiteName = "profileswitch-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)

        circle = CareCircle(context: stack.viewContext)
        circle.id = UUID()
        circle.name = "Test Family"
        circle.joinCode = "123456"
        circle.createdAt = Date()

        supervisor = makePerson(name: "Supervisor", role: Roles.primarySupervisor, in: circle)
        circle.primarySupervisorPersonID = supervisor.id
        client = makePerson(name: "Grandpa", role: Roles.managedClient, in: circle)
        try stack.viewContext.save()
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        stack = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makePerson(name: String, role: String, in circle: CareCircle) -> Person {
        let person = Person(context: stack.viewContext)
        person.id = UUID()
        person.name = name
        person.role = role
        person.languagePreference = "en"
        person.careCircle = circle
        return person
    }

    private func makeCoordinator(currentPerson: Person?) -> ProfileSwitchCoordinator {
        let coordinator = ProfileSwitchCoordinator(stack: stack, defaults: defaults)
        coordinator.currentPersonProvider = { currentPerson }
        return coordinator
    }

    // MARK: - actAs preconditions

    func test_actAs_setsActingPersonIDOnSuccess() throws {
        let coordinator = makeCoordinator(currentPerson: supervisor)
        try coordinator.actAs(personID: client.id!)
        XCTAssertEqual(coordinator.actingPersonID, client.id)
    }

    func test_actAs_throwsNotPrimaryWhenActorIsSecondary() throws {
        let secondary = makePerson(name: "Aunt", role: Roles.secondarySupervisor, in: circle)
        try stack.viewContext.save()
        let coordinator = makeCoordinator(currentPerson: secondary)
        XCTAssertThrowsError(try coordinator.actAs(personID: client.id!)) { error in
            XCTAssertEqual(error as? ProfileSwitchError, .notPrimarySupervisor)
        }
        XCTAssertNil(coordinator.actingPersonID)
    }

    func test_actAs_throwsSelfTargetWhenTargetEqualsActor() {
        let coordinator = makeCoordinator(currentPerson: supervisor)
        XCTAssertThrowsError(try coordinator.actAs(personID: supervisor.id!)) { error in
            XCTAssertEqual(error as? ProfileSwitchError, .selfTargetNotAllowed)
        }
    }

    func test_actAs_throwsIneligibleWhenTargetIsAnotherSupervisor() throws {
        let secondary = makePerson(name: "Aunt", role: Roles.secondarySupervisor, in: circle)
        try stack.viewContext.save()
        let coordinator = makeCoordinator(currentPerson: supervisor)
        XCTAssertThrowsError(try coordinator.actAs(personID: secondary.id!)) { error in
            XCTAssertEqual(error as? ProfileSwitchError, .targetIneligible)
        }
    }

    func test_actAs_throwsNotInCircleWhenTargetCrossesCircle() throws {
        let otherCircle = CareCircle(context: stack.viewContext)
        otherCircle.id = UUID()
        otherCircle.name = "Other Family"
        otherCircle.createdAt = Date()
        let stranger = makePerson(name: "Stranger", role: Roles.managedClient, in: otherCircle)
        try stack.viewContext.save()
        let coordinator = makeCoordinator(currentPerson: supervisor)
        XCTAssertThrowsError(try coordinator.actAs(personID: stranger.id!)) { error in
            XCTAssertEqual(error as? ProfileSwitchError, .targetNotInSameCircle)
        }
    }

    func test_actAs_throwsNotFoundWhenTargetMissing() {
        let coordinator = makeCoordinator(currentPerson: supervisor)
        XCTAssertThrowsError(try coordinator.actAs(personID: UUID())) { error in
            XCTAssertEqual(error as? ProfileSwitchError, .targetNotFound)
        }
    }

    // MARK: - switchBack / actorPerson

    func test_switchBack_clearsActingPersonID() throws {
        let coordinator = makeCoordinator(currentPerson: supervisor)
        try coordinator.actAs(personID: client.id!)
        coordinator.switchBack()
        XCTAssertNil(coordinator.actingPersonID)
        XCTAssertNil(defaults.string(forKey: ProfileSwitchCoordinator.defaultsKey))
    }

    func test_actorPerson_returnsActingTargetWhenSet() throws {
        let coordinator = makeCoordinator(currentPerson: supervisor)
        try coordinator.actAs(personID: client.id!)
        XCTAssertEqual(coordinator.actorPerson?.id, client.id)
    }

    func test_actorPerson_returnsCurrentPersonWhenActingPersonIDNil() {
        let coordinator = makeCoordinator(currentPerson: supervisor)
        XCTAssertEqual(coordinator.actorPerson?.id, supervisor.id)
    }

    // MARK: - Persistence round-trip (D6)

    func test_actingPersonID_persistsToAppStorage() throws {
        let coordinator = makeCoordinator(currentPerson: supervisor)
        try coordinator.actAs(personID: client.id!)
        XCTAssertEqual(defaults.string(forKey: ProfileSwitchCoordinator.defaultsKey),
                       client.id!.uuidString)
    }

    func test_actingPersonID_hydratesFromAppStorageOnInit() throws {
        let first = makeCoordinator(currentPerson: supervisor)
        try first.actAs(personID: client.id!)
        // A second coordinator over the same defaults + store is the
        // relaunch: the act-as state must survive the cold start.
        let relaunched = makeCoordinator(currentPerson: supervisor)
        XCTAssertEqual(relaunched.actingPersonID, client.id)
        XCTAssertEqual(relaunched.actorPerson?.id, client.id)
    }

    func test_actingPersonID_clearsGracefullyOnOrphanedUUID() {
        // Edge case 9e: the stored UUID no longer resolves to a Person.
        defaults.set(UUID().uuidString, forKey: ProfileSwitchCoordinator.defaultsKey)
        let coordinator = makeCoordinator(currentPerson: supervisor)
        XCTAssertNil(coordinator.actingPersonID)
        XCTAssertNil(defaults.string(forKey: ProfileSwitchCoordinator.defaultsKey),
                     "an orphaned acting_person_id must be removed, not left to re-trip on every launch")
        XCTAssertEqual(coordinator.actorPerson?.id, supervisor.id)
    }

    // MARK: - Error distinctness

    func test_errorCasesAreDistinct() {
        // Type-level guard mirroring ErrorCollapseConventionTests: every
        // ProfileSwitchError case maps to its own user-facing copy, so the
        // cases must stay pairwise distinct. (No `.offline` analog on
        // purpose — the switch is a purely local operation.)
        let all: [ProfileSwitchError] = [
            .notPrimarySupervisor, .selfTargetNotAllowed,
            .targetNotInSameCircle, .targetIneligible, .targetNotFound
        ]
        for (i, lhs) in all.enumerated() {
            for (j, rhs) in all.enumerated() where i != j {
                XCTAssertNotEqual(lhs, rhs)
            }
        }
    }

    // MARK: - AuthGate routing (Part 12d)

    func test_authGate_routesToTodayViewWhenActingAsManagedClient() {
        // In act-as the actor's role is the TARGET's role — a client role
        // routes to TodayView even though the Firebase identity is primary.
        XCTAssertEqual(AuthGate.route(needsCircleSetup: false, actorRole: Roles.managedClient),
                       .todayView)
        XCTAssertEqual(AuthGate.route(needsCircleSetup: false, actorRole: Roles.deviceClient),
                       .todayView)
    }

    func test_authGate_routesToSupervisorDashboardWhenActingPersonIDNil() {
        // actingPersonID == nil means actorPerson == currentPerson — the
        // original supervisor routing is unchanged.
        XCTAssertEqual(AuthGate.route(needsCircleSetup: false, actorRole: Roles.primarySupervisor),
                       .supervisorDashboard)
        XCTAssertEqual(AuthGate.route(needsCircleSetup: false, actorRole: Roles.secondarySupervisor),
                       .supervisorDashboard)
        XCTAssertEqual(AuthGate.route(needsCircleSetup: false, actorRole: Roles.legacySupervisor),
                       .supervisorDashboard)
        XCTAssertEqual(AuthGate.route(needsCircleSetup: true, actorRole: Roles.primarySupervisor),
                       .circleSetup)
    }
}
