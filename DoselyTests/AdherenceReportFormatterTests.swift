import XCTest
@testable import Dosely

/// Pins the plain-text body / subject formatting: the empty-vs-populated
/// missed-doses branches, the language switch, the Western-Arabic-numerals
/// rule, and the disclaimer.
final class AdherenceReportFormatterTests: XCTestCase {

    private func sampleReport(missed: Bool) -> AdherenceReport {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -6, to: now)!
        let meds = [AdherenceReport.MedicationSummary(
            id: UUID(), name: "Warfarin", dose: "5mg", takenCount: 6, scheduledCount: 7
        )]
        let missedDoses: [AdherenceReport.MissedDose] = missed
            ? [AdherenceReport.MissedDose(medicationName: "Warfarin", scheduledAt: now)]
            : []
        return AdherenceReport(patientName: "Grandpa", dateRange: start...now, medications: meds,
                               overallTakenCount: 6, overallScheduledCount: 7, missedDoses: missedDoses)
    }

    func test_emptyMissed_showsNoMissedLine() {
        let body = AdherenceReportFormatter(language: "en").plainTextBody(for: sampleReport(missed: false))
        XCTAssertTrue(body.contains("No missed doses in this period."))
    }

    func test_withMissed_listsEachWithTimestamp() {
        let body = AdherenceReportFormatter(language: "en").plainTextBody(for: sampleReport(missed: true))
        XCTAssertFalse(body.contains("No missed doses"))
        XCTAssertTrue(body.contains("Warfarin"))
        XCTAssertTrue(body.contains("scheduled"))
    }

    func test_englishVsPunjabi_produceDifferentLabels() {
        let en = AdherenceReportFormatter(language: "en").plainTextBody(for: sampleReport(missed: false))
        let pa = AdherenceReportFormatter(language: "pa").plainTextBody(for: sampleReport(missed: false))
        XCTAssertNotEqual(en, pa)
        XCTAssertTrue(en.contains("Adherence report"))
        XCTAssertFalse(pa.contains("Adherence report"), "the Punjabi body must use Punjabi labels")
    }

    func test_numbersStayLatinEvenInPunjabi() {
        let pa = AdherenceReportFormatter(language: "pa").plainTextBody(for: sampleReport(missed: true))
        XCTAssertTrue(pa.contains("86"), "the 86% figure must be Western Arabic")
        let gurmukhiDigits = CharacterSet(charactersIn: "੦੧੨੩੪੫੬੭੮੯")
        XCTAssertNil(pa.rangeOfCharacter(from: gurmukhiDigits),
                     "numbers must stay Latin per the Western-Arabic-everywhere rule")
    }

    func test_disclaimerAppearsInBody() {
        let en = AdherenceReportFormatter(language: "en").plainTextBody(for: sampleReport(missed: false))
        XCTAssertTrue(en.contains("generated automatically by the Dosely"))
    }

    func test_subjectContainsPatientName() {
        let subject = AdherenceReportFormatter(language: "en").subject(for: sampleReport(missed: false))
        XCTAssertTrue(subject.contains("Grandpa"))
    }
}
