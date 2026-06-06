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
}
