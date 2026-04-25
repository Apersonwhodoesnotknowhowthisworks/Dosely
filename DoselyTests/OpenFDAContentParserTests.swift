import XCTest
@testable import Dosely

final class OpenFDAContentParserTests: XCTestCase {

    // MARK: - parseBulletList

    func testBulletMarkers() {
        let input = "• Nausea\n• Headache\n• Dizziness"
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["Nausea", "Headache", "Dizziness"])
    }

    func testHyphenBulletsRequireSpace() {
        let input = "- Nausea\n- Headache\n- Dizziness"
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["Nausea", "Headache", "Dizziness"])
    }

    func testNumberedList() {
        let input = "1. Bleeding 2. Stroke 3. Fall risk"
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["Bleeding", "Stroke", "Fall risk"])
    }

    func testParenthesisedNumberedList() {
        let input = "(1) Bleeding (2) Stroke (3) Fall risk"
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["Bleeding", "Stroke", "Fall risk"])
    }

    func testSemicolonList() {
        let input = "Bleeding events; gastrointestinal upset; mild bruising"
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["Bleeding events", "gastrointestinal upset", "mild bruising"])
    }

    func testIntroducerCommaList() {
        let input = "Common adverse reactions include nausea, headache, dizziness, and constipation."
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["nausea", "headache", "dizziness", "constipation"])
    }

    func testIntroducerHandlesSuchAs() {
        let input = "Frequent side effects, such as nausea, vomiting, dizziness, were reported."
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["nausea", "vomiting", "dizziness"])
    }

    func testSingleSentenceNoListSignalReturnsEmpty() {
        let input = "This medication is used for the prevention of stroke in adults with non-valvular atrial fibrillation"
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input), [])
    }

    func testItemsShorterThan3CharsFiltered() {
        let input = "ab; cd; valid item one; valid item two"
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["valid item one", "valid item two"])
    }

    func testItemsLongerThan140CharsFiltered() {
        let longItem = String(repeating: "a", count: 200)
        let input = "Item one; Item two; \(longItem)"
        XCTAssertEqual(OpenFDAContentParser.parseBulletList(input),
                       ["Item one", "Item two"])
    }

    // MARK: - summarizeFirstSentence

    func testSummarizeFirstSentence() {
        XCTAssertEqual(
            OpenFDAContentParser.summarizeFirstSentence("First sentence. Second sentence."),
            "First sentence."
        )
    }

    func testSummarizeRespectsEgAbbreviation() {
        let input = "Used for various conditions, e.g. arthritis. Take as directed."
        XCTAssertEqual(
            OpenFDAContentParser.summarizeFirstSentence(input),
            "Used for various conditions, e.g. arthritis."
        )
    }

    func testSummarizeRespectsDrAbbreviation() {
        let input = "Dr. Smith prescribed this medication. Take with food."
        XCTAssertEqual(
            OpenFDAContentParser.summarizeFirstSentence(input),
            "Dr. Smith prescribed this medication."
        )
    }

    func testSummarizeTruncatesAtWordBoundaryWithEllipsis() {
        let input = String(repeating: "word ", count: 100)
        let result = OpenFDAContentParser.summarizeFirstSentence(input, max: 30)
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertLessThanOrEqual(result.count, 31)
    }

    // MARK: - parse(_:) — orchestration

    func testTakeItNowFilteredAndReminderAppended() {
        let drug = OpenFDADrug(
            brandName: "X", genericName: "x",
            indications: nil,
            dosageAndAdministration: "Take it now with food.",
            warnings: nil, adverseReactions: nil,
            sourceURL: ""
        )
        let parsed = OpenFDAContentParser.parse(drug)
        XCTAssertNotNil(parsed.howToTake)
        XCTAssertFalse(parsed.howToTake!.lowercased().contains("take it now"))
        XCTAssertTrue(parsed.howToTake!.contains("Always follow your doctor's instructions"))
    }

    func testParseProducesFullyPopulatedContent() {
        let drug = OpenFDADrug(
            brandName: "Eliquis",
            genericName: "apixaban",
            indications: "Used to reduce risk of stroke. Multiple sentences here.",
            dosageAndAdministration: "Take 5 mg twice daily with water.",
            warnings: "Risk of bleeding; risk of stroke; spinal hematoma",
            adverseReactions: "Common reactions include nausea, headache, and dizziness.",
            sourceURL: "https://example.com"
        )
        let parsed = OpenFDAContentParser.parse(drug)
        XCTAssertEqual(parsed.whatItDoes, "Used to reduce risk of stroke.")
        XCTAssertNotNil(parsed.howToTake)
        XCTAssertEqual(parsed.warnings,
                       ["Risk of bleeding", "risk of stroke", "spinal hematoma"])
        XCTAssertEqual(parsed.commonSideEffects,
                       ["nausea", "headache", "dizziness"])
        XCTAssertTrue(parsed.rawFallback.isEmpty,
                      "Both list fields parsed cleanly, so no fallback expected.")
    }

    func testParseStashesRawFallbackWhenListDetectionFails() {
        // Single long prose paragraph for warnings — the parser should fall
        // back to a one-item summary AND keep the verbatim text under
        // rawFallback["Warnings"].
        let prose = "This medication carries serious risks that patients should be aware of before starting therapy and should be reviewed with the prescriber."
        let drug = OpenFDADrug(
            brandName: "X", genericName: "x",
            indications: nil, dosageAndAdministration: nil,
            warnings: prose, adverseReactions: nil,
            sourceURL: ""
        )
        let parsed = OpenFDAContentParser.parse(drug)
        XCTAssertEqual(parsed.warnings.count, 1)
        XCTAssertEqual(parsed.rawFallback["Warnings"], prose)
    }

    func testParseHandlesAllNilFields() {
        let drug = OpenFDADrug(
            brandName: nil, genericName: nil,
            indications: nil, dosageAndAdministration: nil,
            warnings: nil, adverseReactions: nil,
            sourceURL: ""
        )
        let parsed = OpenFDAContentParser.parse(drug)
        XCTAssertNil(parsed.whatItDoes)
        XCTAssertNil(parsed.howToTake)
        XCTAssertEqual(parsed.commonSideEffects, [])
        XCTAssertEqual(parsed.warnings, [])
        XCTAssertTrue(parsed.rawFallback.isEmpty)
    }
}
