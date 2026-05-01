import CoreData
import XCTest
@testable import Dosely

/// Coverage for the role-aware filter on `SupervisorDashboardViewModel.load`.
///
/// The selector strip on the Today tab and the "All" combined-doses
/// view both read `viewModel.clients`. The previous filter only
/// excluded the acting supervisor's own row, so co-supervisors in the
/// circle leaked through and showed up as if they were patients.
/// Filter is now keyed on role: only `device_client` and
/// `managed_client` are dose-targets per the data model.
@MainActor
final class SupervisorDashboardViewModelTests: XCTestCase {
    private var stack: CoreDataStack!
    private var personRepo: PersonRepository!
    private var medRepo: MedicationRepository!
    private var careCircleRepo: CareCircleRepository!
    private var viewModel: SupervisorDashboardViewModel!
    private var circle: CareCircle!
    private var primary: Person!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        let noFirestore = FirestoreService()
        personRepo = PersonRepository(stack: stack, firestore: noFirestore)
        medRepo = MedicationRepository(stack: stack, firestore: noFirestore)
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        viewModel = SupervisorDashboardViewModel(
            medicationRepo: medRepo,
            personRepo: personRepo
        )
        circle = await careCircleRepo.createCareCircle(
            name: "Test", foundingSupervisorFirebaseUID: "uid-primary", founderName: "Primary"
        )
        primary = await personRepo.fetchSupervisor(firebaseUID: "uid-primary")
    }

    override func tearDown() {
        stack = nil
        personRepo = nil
        medRepo = nil
        careCircleRepo = nil
        viewModel = nil
        circle = nil
        primary = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func addSecondarySupervisor(uid: String, name: String) async -> Person {
        let result = await careCircleRepo.joinCareCircle(
            code: circle.joinCode!,
            asSupervisorWithFirebaseUID: uid,
            name: name
        )
        guard case .success = result else {
            XCTFail("failed to seed secondary supervisor"); return primary
        }
        // joinCareCircle stamps role = secondary_supervisor on the new
        // Person row, so a fetch by firebaseUID returns the secondary.
        return await personRepo.fetchSupervisor(firebaseUID: uid)!
    }

    private func addManagedClient(name: String) async throws -> Person {
        try await personRepo.createManagedClient(
            name: name,
            photoData: nil,
            language: "en",
            in: circle,
            actorPersonID: primary.id!
        )
    }

    // MARK: - Role-aware filter

    /// Two managed clients + two supervisors in the circle. The
    /// dashboard's `clients` array — what the selector strip and the
    /// "All" doses path both read — must contain exactly the two
    /// managed clients. The selector adds its own "All" avatar at the
    /// top, so the user-visible count would be 3.
    func test_load_clientsExcludesEverySupervisorFlavor() async throws {
        _ = await addSecondarySupervisor(uid: "uid-co", name: "Co-Supervisor")
        let grandpa = try await addManagedClient(name: "Grandpa")
        let bibi = try await addManagedClient(name: "Bibi")

        await viewModel.load(circleID: circle.id!,
                             supervisorID: primary.id!,
                             activePersonID: nil)

        XCTAssertEqual(viewModel.clients.count, 2,
                       "selector should include only managed/device clients, not supervisors")
        let names = Set(viewModel.clients.compactMap { $0.name })
        XCTAssertEqual(names, ["Bibi", "Grandpa"])
        XCTAssertTrue(viewModel.clients.contains(where: { $0.id == grandpa.id }))
        XCTAssertTrue(viewModel.clients.contains(where: { $0.id == bibi.id }))
    }

    /// Whichever supervisor is the actor, the filter stays the same.
    /// Previously the filter excluded only the *acting* supervisor's
    /// row, so a secondary loading the dashboard saw the primary
    /// listed alongside the clients.
    func test_load_secondarySupervisorAlsoSeesNoSupervisorsInSelector() async throws {
        let secondary = await addSecondarySupervisor(uid: "uid-secondary", name: "Secondary")
        _ = try await addManagedClient(name: "Grandpa")

        await viewModel.load(circleID: circle.id!,
                             supervisorID: secondary.id!,
                             activePersonID: nil)

        XCTAssertEqual(viewModel.clients.count, 1,
                       "secondary supervisor's selector must also exclude the primary")
        XCTAssertEqual(viewModel.clients.first?.name, "Grandpa")
    }

    // MARK: - Alerts (no real signal yet)
    //
    // Until missed-dose rollups, low-supply, PIN lockout, and emergency
    // alerts all ship, the dashboard MUST NOT surface any alert. The
    // previous `stubAlerts` helper produced a hardcoded "Watch %@'s
    // pill supply this week" warning unconditionally — once a person
    // was selected, the alert always appeared, regardless of supply,
    // and the substituted name often didn't match the supervisor's
    // expectation because of stale `activePersonID` state.

    func test_load_alertsAreEmptyWhenAClientWithNoMedicationsIsSelected() async throws {
        let grandpa = try await addManagedClient(name: "Grandpa")

        await viewModel.load(circleID: circle.id!,
                             supervisorID: primary.id!,
                             activePersonID: grandpa.id!)

        XCTAssertTrue(viewModel.alerts.isEmpty,
                      "no real alert signal — selecting a client must not surface a placeholder warning")
    }

    func test_load_alertsAreEmptyOnTheAllView() async throws {
        _ = try await addManagedClient(name: "Grandpa")
        _ = try await addManagedClient(name: "Bibi")

        await viewModel.load(circleID: circle.id!,
                             supervisorID: primary.id!,
                             activePersonID: nil)

        XCTAssertTrue(viewModel.alerts.isEmpty,
                      "the All view must not show alerts until real signals (missed doses, low supply) ship")
    }

    /// "All" view aggregates doses across the filtered clients only.
    /// A scheduled dose on a managed client should land in the combined
    /// list; a scheduled dose on a supervisor (a degenerate but
    /// possible state if the previous bug had let one through) must
    /// not. We verify the latter by asserting the combined list's
    /// medications are the client's, not the supervisor's.
    func test_load_combinedDosesIgnoreSupervisorMedications() async throws {
        _ = await addSecondarySupervisor(uid: "uid-co", name: "Co-Supervisor")
        let grandpa = try await addManagedClient(name: "Grandpa")

        // A scheduled medication on the managed client. Schedules are
        // required for `loadCombinedDoses` to surface anything; without
        // one the combined list is empty regardless of role filtering.
        _ = try await medRepo.saveMedication(
            personID: grandpa.id!,
            actorPersonID: primary.id!,
            name: "Lipitor",
            dose: "20mg",
            pillsPerDose: 1,
            foodRule: "either",
            notes: nil,
            currentSupply: 30,
            pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)]
        )

        await viewModel.load(circleID: circle.id!,
                             supervisorID: primary.id!,
                             activePersonID: nil)

        XCTAssertFalse(viewModel.doses.isEmpty,
                       "scheduled dose on the managed client should show in the combined view")
        for dose in viewModel.doses {
            XCTAssertEqual(dose.medication.personID, grandpa.id,
                           "every combined-view dose must belong to a client, not a supervisor")
        }
    }
}
