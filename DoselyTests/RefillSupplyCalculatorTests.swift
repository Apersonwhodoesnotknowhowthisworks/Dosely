import CoreData
import XCTest
@testable import Dosely

/// Pins `RefillSupplyCalculator`'s schedule-driven math across every shape the
/// app can express, plus the as-needed nil case and the threshold boundary.
/// Builds medications directly in an in-memory context — the calculator is a
/// pure read, so no repository or actor is needed.
final class RefillSupplyCalculatorTests: XCTestCase {
    private var stack: CoreDataStack!

    override func setUp() {
        super.setUp()
        stack = CoreDataStack(inMemory: true)
    }
    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    /// One `DoseSchedule` per entry in `dayMasks` (each a daysOfWeek bitmask:
    /// Mon=1 … Sun=64, 127 = every day). Empty array = an as-needed med.
    private func makeMed(supply: Int16, dayMasks: [Int16]) -> Medication {
        let ctx = stack.viewContext
        let med = Medication(context: ctx)
        med.id = UUID()
        med.personID = UUID()
        med.name = "Test"
        med.dose = "10mg"
        med.pillsPerDose = 1
        med.foodRule = "either"
        med.currentSupply = supply
        med.dateAdded = Date()
        for mask in dayMasks {
            let schedule = DoseSchedule(context: ctx)
            schedule.id = UUID()
            schedule.timeOfDay = "08:00"
            schedule.daysOfWeek = mask
            schedule.medication = med
        }
        try? ctx.save()
        return med
    }

    // MARK: - dosesPerDay

    func test_dosesPerDay_onceDaily() {
        XCTAssertEqual(RefillSupplyCalculator.dosesPerDay(for: makeMed(supply: 30, dayMasks: [127]))!,
                       1.0, accuracy: 0.0001)
    }
    func test_dosesPerDay_twiceDaily() {
        XCTAssertEqual(RefillSupplyCalculator.dosesPerDay(for: makeMed(supply: 60, dayMasks: [127, 127]))!,
                       2.0, accuracy: 0.0001)
    }
    func test_dosesPerDay_threeTimesDaily() {
        XCTAssertEqual(RefillSupplyCalculator.dosesPerDay(for: makeMed(supply: 90, dayMasks: [127, 127, 127]))!,
                       3.0, accuracy: 0.0001)
    }
    func test_dosesPerDay_fourTimesDaily() {
        XCTAssertEqual(RefillSupplyCalculator.dosesPerDay(for: makeMed(supply: 90, dayMasks: [127, 127, 127, 127]))!,
                       4.0, accuracy: 0.0001)
    }
    func test_dosesPerDay_weekly() {
        // One schedule on Mondays only (mask 1) → 1 dose/week → 1/7 per day.
        XCTAssertEqual(RefillSupplyCalculator.dosesPerDay(for: makeMed(supply: 4, dayMasks: [1]))!,
                       1.0 / 7.0, accuracy: 0.0001)
    }
    func test_dosesPerDay_everyOtherDayApprox() {
        // Mon/Wed/Fri/Sun (1+4+16+64 = 85) → 4 doses/week.
        XCTAssertEqual(RefillSupplyCalculator.dosesPerDay(for: makeMed(supply: 10, dayMasks: [85]))!,
                       4.0 / 7.0, accuracy: 0.0001)
    }
    func test_dosesPerDay_asNeededIsNil() {
        XCTAssertNil(RefillSupplyCalculator.dosesPerDay(for: makeMed(supply: 30, dayMasks: [])))
    }

    // MARK: - daysRemaining

    func test_daysRemaining_twiceDaily() {
        // 60 pills at 2/day = 30 days.
        XCTAssertEqual(RefillSupplyCalculator.daysRemaining(for: makeMed(supply: 60, dayMasks: [127, 127]))!,
                       30.0, accuracy: 0.0001)
    }
    func test_daysRemaining_weekly() {
        // 4 pills at 1/week (1/7 per day) = 28 days.
        XCTAssertEqual(RefillSupplyCalculator.daysRemaining(for: makeMed(supply: 4, dayMasks: [1]))!,
                       28.0, accuracy: 0.0001)
    }
    func test_daysRemaining_asNeededIsNil() {
        XCTAssertNil(RefillSupplyCalculator.daysRemaining(for: makeMed(supply: 30, dayMasks: [])))
    }

    // MARK: - isLow boundary

    func test_isLow_falseAtExactlyThreshold() {
        // once-daily, supply 7 → exactly 7 days → NOT low (strict `<`).
        XCTAssertFalse(RefillSupplyCalculator.isLow(for: makeMed(supply: 7, dayMasks: [127])))
    }
    func test_isLow_trueJustBelowThreshold() {
        XCTAssertTrue(RefillSupplyCalculator.isLow(for: makeMed(supply: 6, dayMasks: [127])))
    }
    func test_isLow_falseWellAboveThreshold() {
        XCTAssertFalse(RefillSupplyCalculator.isLow(for: makeMed(supply: 30, dayMasks: [127])))
    }
    func test_isLow_falseForAsNeededEvenAtZero() {
        // An empty bottle of an as-needed med is not a low-supply signal.
        XCTAssertFalse(RefillSupplyCalculator.isLow(for: makeMed(supply: 0, dayMasks: [])))
    }
}
