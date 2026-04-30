import CoreData
import Foundation

/// Centralized role constants and predicates. The single source of truth
/// for the four roles a `Person` can hold:
///
/// - `primary_supervisor`: full read/write of the care circle. Exactly
///   one per circle at all times. The founder of a circle is the primary
///   by default; new joiners are secondary. The current primary can
///   promote a secondary, which atomically demotes the current primary.
/// - `secondary_supervisor`: read-only across the circle. The only
///   write affordances they have are creating alerts (e.g. an emergency
///   button) and acknowledging alerts that involve them.
/// - `device_client`: a non-Firebase user who unlocks the device profile
///   with a 4-digit PIN. Logs their own doses.
/// - `managed_client`: a non-Firebase user with no PIN, fully managed by
///   a supervisor.
///
/// Reads tolerate the legacy `"supervisor"` value as a transitional
/// alias for `primary_supervisor` so that old data populated before the
/// primary/secondary split keeps working until `PrimaryRoleMigration`
/// lands. **Writes must use the new values** — never `"supervisor"`.
enum Roles {
    static let primarySupervisor = "primary_supervisor"
    static let secondarySupervisor = "secondary_supervisor"
    static let deviceClient = "device_client"
    static let managedClient = "managed_client"
    /// Pre-split string. Treated as `primary_supervisor` on the read
    /// side only. Never written by post-split code.
    static let legacySupervisor = "supervisor"

    /// True for either supervisor flavour or the legacy alias. Used for
    /// "is this person allowed to view supervisor-only data?" decisions.
    static func isAnySupervisor(_ role: String?) -> Bool {
        role == primarySupervisor
            || role == secondarySupervisor
            || role == legacySupervisor
    }

    /// True only for the primary or its legacy alias. Used for
    /// "is this person allowed to write?" decisions.
    static func isPrimarySupervisor(_ role: String?) -> Bool {
        role == primarySupervisor || role == legacySupervisor
    }

    /// Convenience for `Person?` callers.
    static func isPrimary(_ person: Person?) -> Bool {
        isPrimarySupervisor(person?.role)
    }

    static func isSecondary(_ person: Person?) -> Bool {
        person?.role == secondarySupervisor
    }
}
