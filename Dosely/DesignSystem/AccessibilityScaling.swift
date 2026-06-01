import SwiftUI

/// Larger-text floor logic for the `force_larger_text` accessibility toggle.
/// The toggle raises the minimum Dynamic Type size to `.accessibility1`, but
/// NEVER reduces a larger system setting — it is a floor, not a cap. Someone
/// whose device is set to `.accessibility5` stays at `.accessibility5`.
enum AccessibilityScaling {
    /// The floor applied to the whole app when "Larger text" is on.
    static let floor: DynamicTypeSize = .accessibility1

    /// The size the root ends up at. Modelled here so the floor-not-cap rule is
    /// unit-testable without hosting the view — `.dynamicTypeSize(floor...)`
    /// (a `PartialRangeFrom`) produces exactly this, clamping up to the floor
    /// and leaving anything already larger untouched.
    static func effectiveSize(forceLargerText: Bool,
                              systemSize: DynamicTypeSize) -> DynamicTypeSize {
        forceLargerText ? max(systemSize, floor) : systemSize
    }
}
