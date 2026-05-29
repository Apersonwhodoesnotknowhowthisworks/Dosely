import CoreData
import Foundation

/// Pure, schedule-aware supply math. No Core Data writes, no async — it
/// reads a `Medication`'s `currentSupply` and its `DoseSchedule` rows and
/// produces a consumption rate and days-remaining estimate.
///
/// Each `DoseSchedule` fires once at its `timeOfDay` on the weekdays set in
/// its `daysOfWeek` bitmask (Mon=1 … Sun=64, 127 = every day). So the doses
/// consumed per week is the sum of set weekday bits across every schedule,
/// and per-day is that over seven. This generalises every shape the app can
/// express: once-daily (one all-days schedule → 1.0/day), twice-daily (two →
/// 2.0/day), weekly (one one-day schedule → 1/7 per day → supply × 7 days),
/// every-other-day-ish (a 3–4-day-a-week mask), etc.
///
/// A medication with no scheduled doses (as-needed / PRN) has no rate to
/// project against, so `dosesPerDay` returns nil and no low-supply signal
/// is produced for it — an empty bottle of an as-needed med is not the same
/// as "running low on a daily med."
///
/// Linear model: one logged "taken" dose consumes one unit of supply (see
/// `MedicationRepository.logDose`). `pillsPerDose > 1` is NOT factored in for
/// MVP — supply is treated as "doses remaining." A 2-pill dose therefore
/// over-states days-remaining; flagged as a Phase 2 correctness item.
struct RefillSupplyCalculator {

    /// Threshold for "low supply." Hardcoded for MVP; a `static` so Phase 2
    /// can swap it for a user-adjustable setting without touching call sites.
    static let lowSupplyThresholdDays: Double = 7

    /// Doses consumed per day from the medication's actual schedule, or nil
    /// when the medication has no scheduled doses (as-needed / custom).
    static func dosesPerDay(for medication: Medication) -> Double? {
        let schedules = (medication.schedules as? Set<DoseSchedule>) ?? []
        let dosesPerWeek = schedules.reduce(0) { running, schedule in
            running + (Int(schedule.daysOfWeek) & 0x7F).nonzeroBitCount
        }
        guard dosesPerWeek > 0 else { return nil }
        return Double(dosesPerWeek) / 7.0
    }

    /// Days of supply left at the current rate, floored at 0. Nil when the
    /// rate is indeterminate (`dosesPerDay` nil).
    static func daysRemaining(for medication: Medication) -> Double? {
        guard let perDay = dosesPerDay(for: medication), perDay > 0 else { return nil }
        let supply = Double(max(0, medication.currentSupply))
        return max(0.0, supply / perDay)
    }

    /// True only when days-remaining is computable AND below the threshold.
    /// An as-needed medication (nil days-remaining) is never "low."
    static func isLow(for medication: Medication) -> Bool {
        guard let days = daysRemaining(for: medication) else { return false }
        return days < lowSupplyThresholdDays
    }
}
