import CoreData
import SwiftUI
import XCTest
@testable import Dosely

/// Renders `AlertsCard` against a Core Data store seeded with one
/// of each alert type and confirms the rendered UIKit hierarchy
/// contains visible text matching the expected copy. Catches the
/// regression where a refactor accidentally drops the type-aware
/// body switch (which would render `Text("")` for everything) or
/// removes the Acknowledge button.
@MainActor
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

    func test_alertsCard_rendersTypeSpecificBodyAndAcknowledgeButton() throws {
        let circleID = UUID()
        let circle = makeCircle(id: circleID)

        let pending = makeAlert(
            type: FirestoreModels.AlertType.missedDose,
            personID: UUID(),
            circle: circle,
            payload: ["personName": "Grandpa", "medicationName": "Metformin"],
            scheduledTime: hour(9),
            createdAt: hour(10)
        )
        let acked = makeAlert(
            type: FirestoreModels.AlertType.emergency,
            personID: UUID(),
            circle: circle,
            payload: ["personName": "Grandpa"],
            scheduledTime: nil,
            createdAt: hour(14, minute: 14),
            ackUID: "uid-other",
            ackName: "Aunt Two"
        )

        var ackedThisAlert: Dosely.Alert?
        let card = AlertsCard(alerts: [pending, acked]) { tapped in
            ackedThisAlert = tapped
        }
        let visible = render(card)

        // missedDose body: "Grandpa missed the 9:00 AM dose of Metformin."
        XCTAssertTrue(visible.contains(where: { $0.contains("Grandpa") && $0.contains("Metformin") }),
                      "missedDose row should reference person + medication; got: \(visible)")
        // emergency row's "Acknowledged by Aunt Two" status text
        XCTAssertTrue(visible.contains(where: { $0.contains("Aunt Two") }),
                      "acknowledged row should show acknowledger's name; got: \(visible)")
        // The pending row should expose an Acknowledge label.
        XCTAssertTrue(visible.contains(where: { $0.contains("Acknowledge") }),
                      "pending alert should render an Acknowledge button; got: \(visible)")

        // Sanity: the closure isn't invoked on render — only on tap.
        XCTAssertNil(ackedThisAlert)
    }

    func test_alertsCard_emptyArrayShowsEmptyCopy() {
        let card = AlertsCard(alerts: []) { _ in }
        let visible = render(card)
        XCTAssertTrue(visible.contains(where: { $0.contains("No active alerts") }),
                      "empty alerts array should render the empty-state copy")
    }

    // MARK: - Helpers

    private func makeCircle(id: UUID) -> CareCircle {
        let context = stack.viewContext
        var made: CareCircle!
        context.performAndWait {
            let circle = CareCircle(context: context)
            circle.id = id
            circle.name = "Test"
            circle.createdAt = Date()
            try? context.save()
            made = circle
        }
        return made
    }

    private func makeAlert(type: String,
                           personID: UUID,
                           circle: CareCircle,
                           payload: [String: String],
                           scheduledTime: Date?,
                           createdAt: Date,
                           ackUID: String? = nil,
                           ackName: String? = nil) -> Dosely.Alert {
        let context = stack.viewContext
        var made: Dosely.Alert!
        context.performAndWait {
            let alert = Dosely.Alert(context: context)
            alert.docID = UUID().uuidString
            alert.type = type
            alert.personID = personID
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

    private func render<V: View>(_ view: V) -> [String] {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return Self.collectVisibleText(in: controller.view)
    }

    private static func collectVisibleText(in view: UIView) -> [String] {
        var found: [String] = []
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            found.append(text)
        }
        if let textView = view as? UITextView, !textView.text.isEmpty {
            found.append(textView.text)
        }
        for sub in view.subviews {
            found.append(contentsOf: collectVisibleText(in: sub))
        }
        return found
    }
}
