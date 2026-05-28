import Foundation

/// Display model for `EmergencyMedicalIDView`. Pure value type: decodes
/// a Core Data `MedicalID` once (reusing the same JSON helpers the
/// editor uses — no parsing logic lives here) and exposes the
/// section-visibility and empty-state decisions the view branches on.
/// Kept free of SwiftUI/Core Data so every rule below is unit-testable
/// without a render or a managed-object context.
struct EmergencyMedicalIDViewModel {
    let hasRecord: Bool
    let dateOfBirth: Date?
    let bloodType: String
    let allergies: [String]
    let conditions: [String]
    let contacts: [FirestoreModels.FEmergencyContact]
    let notes: String

    /// Production path: decode a fetched Core Data row (or its absence).
    init(medicalID: MedicalID?) {
        guard let row = medicalID else {
            self.init(hasRecord: false, dateOfBirth: nil, bloodType: "",
                      allergies: [], conditions: [], contacts: [], notes: "")
            return
        }
        self.init(
            hasRecord: true,
            dateOfBirth: row.dateOfBirth,
            bloodType: (row.bloodType ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            allergies: FirestoreModels.FMedicalID.decodeStringList(row.allergiesJSON),
            conditions: FirestoreModels.FMedicalID.decodeStringList(row.conditionsJSON),
            contacts: FirestoreModels.FMedicalID.decodeContacts(row.emergencyContactsJSON),
            notes: (row.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Memberwise init for tests and previews (no Core Data required).
    init(hasRecord: Bool,
         dateOfBirth: Date?,
         bloodType: String,
         allergies: [String],
         conditions: [String],
         contacts: [FirestoreModels.FEmergencyContact],
         notes: String) {
        self.hasRecord = hasRecord
        self.dateOfBirth = dateOfBirth
        self.bloodType = bloodType
        self.allergies = allergies
        self.conditions = conditions
        self.contacts = contacts
        self.notes = notes
    }

    // MARK: - Section visibility
    //
    // A section renders only when it has content. A skipped section
    // forces a paramedic to actively verify rather than read "Allergies:
    // none" as a positive assertion that could be wrong (the record may
    // simply be incomplete). Same reasoning the build_log entry records.

    var hasDateOfBirth: Bool { dateOfBirth != nil }
    var showBloodType: Bool { !bloodType.isEmpty }
    var showAllergies: Bool { !allergies.isEmpty }
    var showConditions: Bool { !conditions.isEmpty }
    var showContacts: Bool { !contacts.isEmpty }
    var showNotes: Bool { !notes.isEmpty }

    /// Show the "No emergency information saved yet" card when there is
    /// nothing displayable at all. Collapses two cases into one clean
    /// state: no record exists, AND a record exists whose every field is
    /// blank — both must read as "nothing here", never as a grid of
    /// empty placeholders. A record carrying only a date of birth is
    /// *not* empty: the header band shows it.
    var isEmptyState: Bool {
        !(hasDateOfBirth || showBloodType || showAllergies
          || showConditions || showContacts || showNotes)
    }

    /// Age in whole years from the date of birth to now, or nil when no
    /// DOB is on file. Computed against the current calendar.
    func age(asOf now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let dob = dateOfBirth else { return nil }
        return calendar.dateComponents([.year], from: dob, to: now).year
    }

    /// `tel://` URL for a contact's phone, stripping every non-digit
    /// (spaces, dashes, parentheses, a leading "+") so the dialer gets a
    /// clean number. Returns nil when no digits remain.
    static func telURL(from phone: String) -> URL? {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    /// Whether a person with this `role` is someone an emergency Medical
    /// ID is shown for: any client (device or managed). Supervisors are
    /// excluded — they manage their own emergency info elsewhere. Single
    /// source of truth for `TodayView`'s client-tile gate.
    static func isEligibleForMedicalID(role: String?) -> Bool {
        role == Roles.deviceClient || role == Roles.managedClient
    }
}
