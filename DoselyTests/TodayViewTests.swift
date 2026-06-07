import CoreData
import XCTest
@testable import Dosely

/// Role-based visibility for the patient view's supervisor-only affordances,
/// driven through pure static decision helpers (no UIHostingController render
/// walks — see the 2026-05-28 walker-triage lesson), plus one lightweight check
/// that dose-card actions stay on by default for clients (the June 6
/// self-dose-log fix must not be regressed by the add-medication gate).
final class TodayViewTests: XCTestCase {

    // MARK: - Add-medication "+" visibility (supervisor-only write affordance)

    func test_shouldShowAddMedication_hiddenForManagedClient() {
        XCTAssertFalse(TodayView.shouldShowAddMedication(role: Roles.managedClient))
    }

    func test_shouldShowAddMedication_hiddenForDeviceClient() {
        XCTAssertFalse(TodayView.shouldShowAddMedication(role: Roles.deviceClient))
    }

    func test_shouldShowAddMedication_hiddenWhenRoleUnknown() {
        XCTAssertFalse(TodayView.shouldShowAddMedication(role: nil))
    }

    func test_shouldShowAddMedication_visibleForSupervisors() {
        XCTAssertTrue(TodayView.shouldShowAddMedication(role: Roles.primarySupervisor))
        XCTAssertTrue(TodayView.shouldShowAddMedication(role: Roles.secondarySupervisor))
        XCTAssertTrue(TodayView.shouldShowAddMedication(role: Roles.legacySupervisor))
    }

    // MARK: - Debug toolbar role layer (the #if DEBUG build-mode guard is separate)

    func test_shouldShowDebugToolbar_hiddenForClients() {
        XCTAssertFalse(DebugToolbarModifier.shouldShowDebugToolbar(role: Roles.deviceClient))
        XCTAssertFalse(DebugToolbarModifier.shouldShowDebugToolbar(role: Roles.managedClient))
        XCTAssertFalse(DebugToolbarModifier.shouldShowDebugToolbar(role: nil))
    }

    func test_shouldShowDebugToolbar_visibleForSupervisors() {
        XCTAssertTrue(DebugToolbarModifier.shouldShowDebugToolbar(role: Roles.primarySupervisor))
        XCTAssertTrue(DebugToolbarModifier.shouldShowDebugToolbar(role: Roles.secondarySupervisor))
        XCTAssertTrue(DebugToolbarModifier.shouldShowDebugToolbar(role: Roles.legacySupervisor))
    }

    // MARK: - June 6 regression: clients keep Take / Skip / Snooze on their own doses

    @MainActor
    func test_doseCardShowsActionsByDefault_clientsKeepTakeSkipSnooze() {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.viewContext
        let med = Medication(context: ctx)
        med.id = UUID()
        let schedule = DoseSchedule(context: ctx)
        schedule.id = UUID()
        let dose = TodayDose(
            id: schedule.id!, medication: med, schedule: schedule,
            scheduledDate: Date(), log: nil
        )
        // TodayView constructs DoseCardView WITHOUT showActions:, so it defaults
        // to true — a client signed in on their own device keeps Take/Skip/Snooze.
        // (The read-only variant lives on the supervisor dashboard, where it
        // passes showActions: isPrimary.)
        let card = DoseCardView(
            dose: dose, onTake: {}, onSkip: {}, onSnooze: {}, onLearnMore: {}
        )
        XCTAssertTrue(card.showActions)
    }
}
