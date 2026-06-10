import XCTest
@testable import Dosely

/// Coverage for `PersonDetailView`'s "Convert to managed family member"
/// visibility decision. Following the established view-test pattern in this
/// target (see `EditMedicalIDViewTests`), this drives the pure static
/// `shouldShowDemoteSection` helper directly rather than walking an
/// offscreen `UIHostingController` tree — under recent iOS that walk returns
/// `[]`, so the only honest assertion is on the decision logic itself.
///
/// The section is gated on four conditions, each load-bearing: the viewer
/// must be the primary, the target must be a `secondary_supervisor` (NOT the
/// legacy `"supervisor"` alias, which reads as primary), the target must not
/// be the viewer (no self-demotion), and the target must not be the current
/// primary.
final class PersonDetailViewTests: XCTestCase {

    private let actor = UUID()
    private let target = UUID()

    func test_demoteSection_hiddenWhenViewerIsSecondary() {
        XCTAssertFalse(PersonDetailView.shouldShowDemoteSection(
            targetRole: Roles.secondarySupervisor,
            targetPersonID: target,
            actorPersonID: actor,
            primarySupervisorPersonID: actor,
            actorIsPrimary: false
        ))
    }

    func test_demoteSection_hiddenWhenTargetIsActor() {
        XCTAssertFalse(PersonDetailView.shouldShowDemoteSection(
            targetRole: Roles.secondarySupervisor,
            targetPersonID: actor,
            actorPersonID: actor,
            primarySupervisorPersonID: actor,
            actorIsPrimary: true
        ))
    }

    func test_demoteSection_hiddenWhenTargetIsPrimary() {
        // Even with a secondary role string, a target whose id is the
        // circle's current primary must not be offered for demotion.
        XCTAssertFalse(PersonDetailView.shouldShowDemoteSection(
            targetRole: Roles.secondarySupervisor,
            targetPersonID: target,
            actorPersonID: actor,
            primarySupervisorPersonID: target,
            actorIsPrimary: true
        ))
    }

    func test_demoteSection_hiddenForLegacySupervisorTarget() {
        // The legacy "supervisor" alias reads as primary, so it isn't a
        // demotable secondary.
        XCTAssertFalse(PersonDetailView.shouldShowDemoteSection(
            targetRole: Roles.legacySupervisor,
            targetPersonID: target,
            actorPersonID: actor,
            primarySupervisorPersonID: actor,
            actorIsPrimary: true
        ))
    }

    func test_demoteSection_visibleWhenAllConditionsHold() {
        XCTAssertTrue(PersonDetailView.shouldShowDemoteSection(
            targetRole: Roles.secondarySupervisor,
            targetPersonID: target,
            actorPersonID: actor,
            primarySupervisorPersonID: actor,
            actorIsPrimary: true
        ))
    }

    // MARK: - "Switch to this person's view" gate (act-as, D2/D3)

    func test_switchToView_visibleForManagedClientTarget() {
        XCTAssertTrue(PersonDetailView.shouldShowSwitchToView(
            targetRole: Roles.managedClient,
            targetPersonID: target,
            actorPersonID: actor,
            actorIsPrimary: true
        ))
    }

    func test_switchToView_visibleForDeviceClientTarget() {
        XCTAssertTrue(PersonDetailView.shouldShowSwitchToView(
            targetRole: Roles.deviceClient,
            targetPersonID: target,
            actorPersonID: actor,
            actorIsPrimary: true
        ))
    }

    func test_switchToView_hiddenWhenViewerIsNotPrimary() {
        // D2: only the primary can initiate a switch (Phase 2 widens).
        XCTAssertFalse(PersonDetailView.shouldShowSwitchToView(
            targetRole: Roles.managedClient,
            targetPersonID: target,
            actorPersonID: actor,
            actorIsPrimary: false
        ))
    }

    func test_switchToView_hiddenForSupervisorTargets() {
        // D3: never another supervisor — they'd see the same dashboard the
        // primary already has. The legacy alias reads as primary, so it is
        // excluded too.
        for role in [Roles.primarySupervisor, Roles.secondarySupervisor, Roles.legacySupervisor] {
            XCTAssertFalse(PersonDetailView.shouldShowSwitchToView(
                targetRole: role,
                targetPersonID: target,
                actorPersonID: actor,
                actorIsPrimary: true
            ), "switch affordance must be hidden for target role \(role)")
        }
    }

    func test_switchToView_hiddenWhenTargetIsActor() {
        XCTAssertFalse(PersonDetailView.shouldShowSwitchToView(
            targetRole: Roles.managedClient,
            targetPersonID: actor,
            actorPersonID: actor,
            actorIsPrimary: true
        ))
    }

    func test_switchToView_hiddenWhenTargetIDMissing() {
        XCTAssertFalse(PersonDetailView.shouldShowSwitchToView(
            targetRole: Roles.managedClient,
            targetPersonID: nil,
            actorPersonID: actor,
            actorIsPrimary: true
        ))
    }
}
