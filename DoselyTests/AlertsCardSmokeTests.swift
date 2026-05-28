import CoreData
import SwiftUI
import XCTest
@testable import Dosely

/// Coverage for `AlertsCard`'s presentation logic — the type-aware
/// body copy and the three-way ack-row state. These were previously
/// `UIHostingController` render-walk "smoke" tests, but under recent
/// iOS SwiftUI no longer materialises `Text` as `UILabel`s in the
/// offscreen UIView tree, so the walker found nothing and the asserts
/// were vacuous. The logic worth guarding (the type switch and the
/// ack branch) now lives in pure static helpers on `AlertsCard`, and
/// these tests hit them directly — same proof, no opaque tree walk.
final class AlertsCardSmokeTests: XCTestCase {
    private var stack: CoreDataStack!

    override func setUp() {
        super.setUp()
        stack = CoreDataStack(inMemory: true)
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    // MARK: - Body copy

    /// missedDose body interpolates person + medication. A refactor
    /// that drops the type switch would return "" here.
    func test_bodyText_referencesPersonAndMedicationForMissedDose() {
        let alert = makeAlert(
            type: FirestoreModels.AlertType.missedDose,
            payload: ["personName": "Grandpa", "medicationName": "Metformin"],
            scheduledTime: hour(9),
            createdAt: hour(10)
        )
        let body = AlertsCard.bodyText(for: alert)
        XCTAssertTrue(body.contains("Grandpa") && body.contains("Metformin"),
                      "missedDose body must reference person + medication; got: \(body)")
    }

    /// Each alert type maps to its own SF Symbol. This is the
    /// "catches refactors that drop the type switch" guard the old
    /// render test was reaching for — asserted at the source.
    func test_iconName_isTypeSpecificPerAlertType() {
        let missed = makeAlert(type: FirestoreModels.AlertType.missedDose,
                               payload: [:], scheduledTime: nil, createdAt: hour(10))
        let emergency = makeAlert(type: FirestoreModels.AlertType.emergency,
                                  payload: [:], scheduledTime: nil, createdAt: hour(10))
        let weekly = makeAlert(type: FirestoreModels.AlertType.weeklySummary,
                               payload: [:], scheduledTime: nil, createdAt: hour(10))

        XCTAssertEqual(AlertsCard.iconName(for: missed), "clock.fill")
        XCTAssertEqual(AlertsCard.iconName(for: emergency), "exclamationmark.triangle.fill")
        XCTAssertEqual(AlertsCard.iconName(for: weekly), "chart.bar.fill")
    }

    // MARK: - Ack state

    /// An alert acknowledged by a named supervisor renders the
    /// "Acknowledged by …" status, not the button.
    func test_ackState_isAcknowledgedWhenAckNamePresent() {
        let acked = makeAlert(
            type: FirestoreModels.AlertType.emergency,
            payload: ["personName": "Grandpa"],
            scheduledTime: nil,
            createdAt: hour(14, minute: 14),
            ackUID: "uid-other",
            ackName: "Aunt Two"
        )
        XCTAssertEqual(AlertsCard.ackState(for: acked), .acknowledged(name: "Aunt Two"))
    }

    /// A fresh, unacknowledged alert is actionable — the card renders
    /// the Acknowledge button for it.
    func test_ackState_isActionableWhenUnacknowledged() {
        let pending = makeAlert(
            type: FirestoreModels.AlertType.missedDose,
            payload: ["personName": "Grandpa", "medicationName": "Metformin"],
            scheduledTime: hour(9),
            createdAt: hour(10)
        )
        XCTAssertEqual(AlertsCard.ackState(for: pending), .actionable)
    }

    /// Acked by a UID with no name (a race or a legacy row) falls back
    /// to the "acknowledged by unknown" copy rather than the button.
    func test_ackState_isUnknownWhenAckedByUIDWithoutName() {
        let acked = makeAlert(
            type: FirestoreModels.AlertType.missedDose,
            payload: [:],
            scheduledTime: nil,
            createdAt: hour(10),
            ackUID: "uid-only",
            ackName: nil
        )
        XCTAssertEqual(AlertsCard.ackState(for: acked), .acknowledgedByUnknown)
    }

    // MARK: - Helpers

    private func makeAlert(type: String,
                           payload: [String: String],
                           scheduledTime: Date?,
                           createdAt: Date,
                           ackUID: String? = nil,
                           ackName: String? = nil) -> Dosely.Alert {
        let context = stack.viewContext
        var made: Dosely.Alert!
        context.performAndWait {
            let circle = CareCircle(context: context)
            circle.id = UUID()
            circle.name = "Test"
            circle.createdAt = Date()

            let alert = Dosely.Alert(context: context)
            alert.docID = UUID().uuidString
            alert.type = type
            alert.personID = UUID()
            alert.scheduledTime = scheduledTime
            alert.createdAt = createdAt
            alert.payloadJSON = FirestoreModels.FAlert.encodePayload(payload)
            alert.acknowledgedByFirebaseUID = ackUID
            alert.acknowledgedByName = ackName
            alert.acknowledgedAt = ackUID == nil ? nil : createdAt
            alert.careCircle = circle
            try? context.save()
            made = alert
        }
        return made
    }

    private func hour(_ h: Int, minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: h, minute: minute, second: 0, of: Date()) ?? Date()
    }
}
