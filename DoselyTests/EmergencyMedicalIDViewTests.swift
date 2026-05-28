import CoreData
import SwiftUI
import XCTest
@testable import Dosely

/// Coverage for `EmergencyMedicalIDView` — the read-only paramedic
/// viewer. Two kinds of proof here, and deliberately NOT a third:
///
///  - Render smoke: a populated record and a no-record person each
///    build and lay out in a `UIHostingController` without crashing.
///    This exercises the real `init → fetchLocalSync → view-model decode`
///    path against an in-memory store.
///  - Decode integrity: a row round-trips through the repository's sync
///    read into the view model with every section intact.
///  - Eligibility: the static gate the client tiles read.
///
/// What this file does NOT do is walk the `UIView` tree for specific
/// label text. Under recent iOS, SwiftUI no longer materialises `Text`
/// as `UILabel`s in the offscreen hierarchy, so such walks return `[]`
/// and the asserts are vacuous (see `AlertsCardSmokeTests` /
/// `EditMedicalIDViewTests` for the same lesson, 2026-05-28). The
/// section-visibility and copy decisions are proven directly on
/// `EmergencyMedicalIDViewModel` in `EmergencyMedicalIDViewModelTests`.
@MainActor
final class EmergencyMedicalIDViewTests: XCTestCase {
    private var stack: CoreDataStack!
    private var personRepo: PersonRepository!
    private var careCircleRepo: CareCircleRepository!
    private var medicalIDRepo: MedicalIDRepository!
    private var circle: CareCircle!
    private var supervisor: Person!
    private var grandpa: Person!

    override func setUp() async throws {
        try await super.setUp()
        stack = CoreDataStack(inMemory: true)
        let noFirestore = FirestoreService()
        personRepo = PersonRepository(stack: stack, firestore: noFirestore)
        careCircleRepo = CareCircleRepository(stack: stack, firestore: noFirestore)
        medicalIDRepo = MedicalIDRepository(stack: stack, firestore: noFirestore)
        circle = await careCircleRepo.createCareCircle(
            name: "T", foundingSupervisorFirebaseUID: "f", founderName: "F"
        )
        supervisor = await personRepo.fetchSupervisor(firebaseUID: "f")
        grandpa = try await personRepo.createManagedClient(
            name: "Grandpa", photoData: nil, language: "en",
            in: circle, actorPersonID: supervisor.id!
        )
    }

    override func tearDown() {
        stack = nil; personRepo = nil; careCircleRepo = nil; medicalIDRepo = nil
        circle = nil; supervisor = nil; grandpa = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func upsertMedicalID(
        bloodType: String = "O+",
        allergies: [String] = ["Penicillin"],
        conditions: [String] = ["Hypertension"],
        contacts: [FirestoreModels.FEmergencyContact] = [
            FirestoreModels.FEmergencyContact(name: "Aunt Bibi", relationship: "Daughter", phone: "555-0101")
        ],
        notes: String? = "Uses a hearing aid"
    ) {
        let id = grandpa.id!
        stack.viewContext.performAndWait {
            let f = FirestoreModels.FMedicalID(
                id: id.uuidString,
                personID: id.uuidString,
                dateOfBirth: nil,
                bloodType: bloodType,
                allergies: allergies,
                conditions: conditions,
                emergencyContacts: contacts,
                notes: notes,
                updatedAt: Date()
            )
            _ = f.upsert(in: stack.viewContext)
            try? stack.viewContext.save()
        }
    }

    private func render(_ view: some View) {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Proof the body type-checked, built, and produced geometry —
        // i.e. no crash on the init/decode path. Specific copy is
        // asserted on the view model, not by walking this tree.
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
    }

    // MARK: - Render smoke

    func test_populatedRecord_rendersWithoutCrash() {
        upsertMedicalID()
        render(EmergencyMedicalIDView(person: grandpa, repository: medicalIDRepo))
    }

    func test_personWithNoRecord_rendersWithoutCrash() {
        // No upsert — grandpa has no MedicalID row, so the viewer takes
        // the empty-state arm. Must still build and lay out cleanly.
        render(EmergencyMedicalIDView(person: grandpa, repository: medicalIDRepo))
    }

    // MARK: - Decode integrity (sync read → view model)

    /// The viewer reads Core Data synchronously in `init`. Pull the row
    /// back through `fetchLocalSync` and confirm every section the view
    /// branches on survives the decode — the populated path the render
    /// smoke can't assert on without walking the tree.
    func test_fetchLocalSync_decodesEverySectionForViewModel() {
        upsertMedicalID()
        let row = medicalIDRepo.fetchLocalSync(personID: grandpa.id!)
        XCTAssertNotNil(row, "sync read must return the cached row for an offline paramedic view")

        let vm = EmergencyMedicalIDViewModel(medicalID: row)
        XCTAssertTrue(vm.hasRecord)
        XCTAssertFalse(vm.isEmptyState)
        XCTAssertEqual(vm.bloodType, "O+")
        XCTAssertEqual(vm.allergies, ["Penicillin"])
        XCTAssertEqual(vm.conditions, ["Hypertension"])
        XCTAssertEqual(vm.contacts.first?.phone, "555-0101")
        XCTAssertEqual(vm.notes, "Uses a hearing aid")
    }

    /// A record whose text fields are whitespace-only must decode to the
    /// empty state — the `init(medicalID:)` trim is what stops a stray
    /// space from drawing an empty blood-type chip.
    func test_fetchLocalSync_whitespaceOnlyFieldsCollapseToEmptyState() {
        upsertMedicalID(bloodType: "   ", allergies: [], conditions: [],
                        contacts: [], notes: "  ")
        let vm = EmergencyMedicalIDViewModel(medicalID: medicalIDRepo.fetchLocalSync(personID: grandpa.id!))
        XCTAssertTrue(vm.isEmptyState,
                      "whitespace-only fields must trim to empty so no blank cards render")
    }

    // MARK: - Eligibility gate

    /// The client-tile gate shows the Medical ID for clients and hides it
    /// for either supervisor flavour (and the legacy value). Same rule
    /// `TodayView.isClientActor` delegates to.
    func test_eligibility_showsClientsHidesSupervisors() {
        XCTAssertTrue(EmergencyMedicalIDViewModel.isEligibleForMedicalID(role: Roles.deviceClient))
        XCTAssertTrue(EmergencyMedicalIDViewModel.isEligibleForMedicalID(role: Roles.managedClient))

        XCTAssertFalse(EmergencyMedicalIDViewModel.isEligibleForMedicalID(role: Roles.primarySupervisor))
        XCTAssertFalse(EmergencyMedicalIDViewModel.isEligibleForMedicalID(role: Roles.secondarySupervisor))
        XCTAssertFalse(EmergencyMedicalIDViewModel.isEligibleForMedicalID(role: Roles.legacySupervisor))
        XCTAssertFalse(EmergencyMedicalIDViewModel.isEligibleForMedicalID(role: nil))
    }
}
