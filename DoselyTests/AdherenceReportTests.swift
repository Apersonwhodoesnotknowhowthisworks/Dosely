import CoreData
import XCTest
@testable import Dosely

/// Pins `AdherenceReport.build` — pure construction from in-memory medications
/// and dose logs, so no repository or save is needed.
final class AdherenceReportTests: XCTestCase {
    private var stack: CoreDataStack!

    override func setUp() { super.setUp(); stack = CoreDataStack(inMemory: true) }
    override func tearDown() { stack = nil; super.tearDown() }

    private func med(_ name: String, dose: String = "10mg") -> Medication {
        let m = Medication(context: stack.viewContext)
        m.id = UUID(); m.personID = UUID(); m.name = name; m.dose = dose
        m.currentSupply = 30; m.dateAdded = Date()
        return m
    }

    private func log(_ medication: Medication, status: String, at date: Date) -> DoseLog {
        let l = DoseLog(context: stack.viewContext)
        l.id = UUID(); l.medication = medication; l.status = status; l.scheduledTime = date
        return l
    }

    private var range7: ClosedRange<Date> {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now))!
        return start...now
    }

    func test_build_countsTakenScheduledMissed() {
        // 3 meds, 21 logged (taken + missed), 18 taken, 3 missed → 86%.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let m1 = med("Metformin"), m2 = med("Lisinopril"), m3 = med("Warfarin")
        var logs: [DoseLog] = []
        for _ in 0..<7 { logs.append(log(m1, status: "taken", at: yesterday)) }       // 7/7
        for _ in 0..<6 { logs.append(log(m2, status: "taken", at: yesterday)) }       // 6/7
        logs.append(log(m2, status: "missed", at: yesterday))
        for _ in 0..<5 { logs.append(log(m3, status: "taken", at: yesterday)) }       // 5/7
        for _ in 0..<2 { logs.append(log(m3, status: "missed", at: yesterday)) }

        let report = AdherenceReport.build(patientName: "Grandpa",
                                           medications: [m1, m2, m3], doseLogs: logs, in: range7)
        XCTAssertEqual(report.overallTakenCount, 18)
        XCTAssertEqual(report.overallScheduledCount, 21)
        XCTAssertEqual(report.overallPercent, 86)   // 18/21 = 85.7 → 86
        XCTAssertEqual(report.missedDoses.count, 3)
    }

    func test_build_excludesSkippedAndLate() {
        let now = Date()
        let m = med("Metformin")
        let logs = [log(m, status: "taken", at: now),
                    log(m, status: "skipped", at: now),
                    log(m, status: "late", at: now)]
        let report = AdherenceReport.build(patientName: "P", medications: [m], doseLogs: logs, in: range7)
        XCTAssertEqual(report.overallTakenCount, 1)
        XCTAssertEqual(report.overallScheduledCount, 1, "skipped and late don't count toward the denominator")
        XCTAssertEqual(report.overallPercent, 100)
    }

    func test_build_missedDosesDetected() {
        let now = Date()
        let m = med("Warfarin")
        let report = AdherenceReport.build(patientName: "P", medications: [m],
                                           doseLogs: [log(m, status: "missed", at: now),
                                                      log(m, status: "taken", at: now)],
                                           in: range7)
        XCTAssertEqual(report.missedDoses.count, 1)
        XCTAssertEqual(report.missedDoses.first?.medicationName, "Warfarin")
    }

    func test_build_emptyMedications_isZeroPercentNoCrash() {
        let report = AdherenceReport.build(patientName: "P", medications: [], doseLogs: [], in: range7)
        XCTAssertEqual(report.overallPercent, 0)
        XCTAssertTrue(report.medications.isEmpty)
        XCTAssertTrue(report.missedDoses.isEmpty)
    }

    func test_build_respectsDateRange() {
        let now = Date()
        let m = med("Metformin")
        let inRange = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let outOfRange = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let report = AdherenceReport.build(patientName: "P", medications: [m],
                                           doseLogs: [log(m, status: "taken", at: inRange),
                                                      log(m, status: "taken", at: outOfRange)],
                                           in: range7)
        XCTAssertEqual(report.overallTakenCount, 1, "a 30-days-ago dose is outside the 7-day window")
    }

    func test_build_allTaken_is100NotRoundedDown() {
        let now = Date()
        let m = med("Lisinopril")
        let logs = (0..<7).map { _ in log(m, status: "taken", at: now) }
        let report = AdherenceReport.build(patientName: "P", medications: [m], doseLogs: logs, in: range7)
        XCTAssertEqual(report.overallPercent, 100)
        XCTAssertEqual(report.medications.first?.percent, 100)
    }
}
