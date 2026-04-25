import XCTest
@testable import Dosely

final class PrescriptionParserTests: XCTestCase {

    private func line(_ text: String,
                      confidence: Float = 0.9,
                      y: CGFloat = 0.5) -> RecognizedTextLine {
        RecognizedTextLine(text: text,
                           confidence: confidence,
                           boundingBox: CGRect(x: 0.1, y: y, width: 0.7, height: 0.05))
    }

    // MARK: - Name

    func testNamePicksTopMostAlphaLine() {
        let lines = [
            line("Take 1 tablet twice daily", confidence: 0.85, y: 0.5),
            line("Lisinopril",                confidence: 0.95, y: 0.9),
            line("10 mg",                     confidence: 0.9,  y: 0.85)
        ]
        let parsed = PrescriptionParser.parse(lines)
        XCTAssertEqual(parsed.name.value, "Lisinopril")
        XCTAssertEqual(parsed.name.confidence, .high)
    }

    func testNameSkipsLineThatLooksLikeJustADose() {
        let lines = [
            line("500 mg",     confidence: 0.95, y: 0.95),
            line("Metformin",  confidence: 0.95, y: 0.85)
        ]
        let parsed = PrescriptionParser.parse(lines)
        XCTAssertEqual(parsed.name.value, "Metformin")
    }

    // MARK: - Dose

    func testParsesDoseFromLines() {
        let lines = [
            line("Metformin", confidence: 0.95, y: 0.9),
            line("500 mg",    confidence: 0.92, y: 0.85)
        ]
        let parsed = PrescriptionParser.parse(lines)
        XCTAssertEqual(parsed.dose.value, "500mg")
        XCTAssertEqual(parsed.dose.confidence, .high)
    }

    func testParsesDoseWithMcg() {
        let lines = [line("Levothyroxine 50 mcg", confidence: 0.9)]
        let parsed = PrescriptionParser.parse(lines)
        XCTAssertEqual(parsed.dose.value, "50mcg")
    }

    func testNoDoseWhenAbsent() {
        let lines = [line("Take one capsule daily", confidence: 0.9)]
        let parsed = PrescriptionParser.parse(lines)
        XCTAssertEqual(parsed.dose.confidence, .low)
        XCTAssertNil(parsed.dose.value)
    }

    // MARK: - Frequency

    func testFrequencyTwiceDaily() {
        let parsed = PrescriptionParser.parse([line("Take 1 tablet twice daily")])
        XCTAssertEqual(parsed.frequency.value, "Twice daily")
    }

    func testFrequencyOnceDaily() {
        let parsed = PrescriptionParser.parse([line("Once daily in the morning")])
        XCTAssertEqual(parsed.frequency.value, "Once daily")
    }

    func testFrequencyEveryNHours() {
        let parsed = PrescriptionParser.parse([line("Take every 8 hours")])
        XCTAssertEqual(parsed.frequency.value, "Every 8 hours")
    }

    func testFrequencyAsNeeded() {
        let parsed = PrescriptionParser.parse([line("Take as needed for pain")])
        XCTAssertEqual(parsed.frequency.value, "As needed")
    }

    // MARK: - Food rule

    func testFoodRuleWithFood() {
        let parsed = PrescriptionParser.parse([line("Take with food")])
        XCTAssertEqual(parsed.foodRule.value, "with")
        XCTAssertEqual(parsed.foodRule.confidence, .high)
    }

    func testFoodRuleEmptyStomach() {
        let parsed = PrescriptionParser.parse([line("Take on an empty stomach")])
        XCTAssertEqual(parsed.foodRule.value, "without")
    }

    // MARK: - Quantity & pillsPerDose

    func testQuantityWithLabel() {
        let parsed = PrescriptionParser.parse([line("Quantity: 30 tablets")])
        XCTAssertEqual(parsed.quantity.value, 30)
    }

    func testQuantityImpliedByCountWord() {
        let parsed = PrescriptionParser.parse([line("Dispense 60 capsules")])
        XCTAssertEqual(parsed.quantity.value, 60)
    }

    func testPillsPerDose() {
        let parsed = PrescriptionParser.parse([line("Take 2 tablets by mouth twice daily")])
        XCTAssertEqual(parsed.pillsPerDose.value, 2)
        XCTAssertEqual(parsed.pillsPerDose.confidence, .high)
    }

    // MARK: - All-low / fallback

    func testEmptyLinesProduceAllLow() {
        let parsed = PrescriptionParser.parse([])
        XCTAssertTrue(parsed.allFieldsLow)
    }

    func testNonsenseProducesNoStructuredFields() {
        let parsed = PrescriptionParser.parse([
            line("asdfqwerty zxcv lkjh", confidence: 0.6)
        ])
        XCTAssertEqual(parsed.dose.confidence, .low)
        XCTAssertEqual(parsed.frequency.confidence, .low)
        XCTAssertEqual(parsed.foodRule.confidence, .low)
        XCTAssertEqual(parsed.quantity.confidence, .low)
        XCTAssertEqual(parsed.pillsPerDose.confidence, .low)
    }

    // MARK: - End-to-end realistic label

    func testRealisticLabelEndToEnd() {
        // Simulated OCR output for a typical prescription bottle.
        let lines = [
            line("Smith Pharmacy",              confidence: 0.85, y: 0.97),
            line("Lisinopril",                  confidence: 0.96, y: 0.90),
            line("10 mg tablet",                confidence: 0.94, y: 0.84),
            line("Take 1 tablet by mouth once daily", confidence: 0.92, y: 0.70),
            line("Quantity: 30",                confidence: 0.90, y: 0.55),
            line("Refills: 2",                  confidence: 0.88, y: 0.50)
        ]
        let parsed = PrescriptionParser.parse(lines)
        XCTAssertEqual(parsed.name.value, "Lisinopril")
        XCTAssertEqual(parsed.dose.value, "10mg")
        XCTAssertEqual(parsed.frequency.value, "Once daily")
        XCTAssertEqual(parsed.quantity.value, 30)
        XCTAssertEqual(parsed.pillsPerDose.value, 1)
        XCTAssertFalse(parsed.allFieldsLow)
    }
}
