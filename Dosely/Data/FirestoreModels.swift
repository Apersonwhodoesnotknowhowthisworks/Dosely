import CoreData
import FirebaseFirestore
import Foundation

/// Codable document shapes for the Firestore mirror of the Core Data
/// schema. Field names match the Core Data attribute names so a future
/// reader can grep across both layers without translating.
///
/// **Document ids** are the same UUIDs as Core Data — no Firestore
/// auto-ids — so a single id is meaningful in either layer.
///
/// **Reserved shapes** at the bottom (`FMedicalProfile`, `FAlert`,
/// `FFamilyContact`) define the wire format for subcollections that
/// don't yet have Core Data entities. They are not synced today; the
/// shapes exist so that the future feature lands without a schema
/// migration on already-populated production data.
enum FirestoreModels {}

// MARK: - CareCircle

extension FirestoreModels {
    struct FCareCircle: Codable {
        var id: String
        var name: String
        var joinCode: String
        var createdAt: Date
        /// Denormalized count of `Person` rows in this circle whose
        /// role is either supervisor flavour. Maintained by the app via
        /// FieldValue.increment(±1) on supervisor add/remove. Drives the
        /// last-supervisor protection at the rules layer (see
        /// firestore.rules — Person delete requires post-batch count >= 1).
        var supervisorCount: Int
        /// Person.id of the current primary supervisor in this circle.
        /// Exactly one supervisor in the circle holds the
        /// `primary_supervisor` role at all times; this field is the
        /// single source of truth for who that is. `promoteToPrimary`
        /// updates this field atomically with the role swap on both
        /// Person docs and the two `/userMemberships` docs. Optional
        /// because pre-`PrimaryRoleMigration` data has no value yet.
        var primarySupervisorPersonID: String?
        /// Server timestamp for last write. Omitted on encode (Firestore
        /// fills it in via FieldValue.serverTimestamp() at the call site).
        var lastModified: Date?
    }

    struct FJoinCodeIndex: Codable {
        /// Top-level /joinCodes/{code} document — a stable reverse lookup
        /// from join code to circle id. Two writes (one to /careCircles
        /// and one here) must be transactional.
        var careCircleID: String
        var regeneratedAt: Date
    }

    /// Top-level /userMemberships/{firebaseUID} index doc. Binds a
    /// Firebase UID to the (careCircleID, personID, role) tuple so that
    /// Firestore security rules — which can `get()` documents by full
    /// path but cannot run queries — can resolve the current user's
    /// role in O(1).
    ///
    /// `joinCode` is set at create time by joiners only (founders set
    /// nil) and is the rules-layer proof of authority for joining an
    /// existing circle. After create the field is dead weight; we keep
    /// it because there's no rules-layer way to ignore it on read.
    struct FUserMembership: Codable {
        var careCircleID: String
        var personID: String
        var role: String
        var joinedAt: Date
        var joinCode: String?
    }
}

// MARK: - Person

extension FirestoreModels {
    struct FPerson: Codable {
        var id: String
        var careCircleID: String
        var name: String
        var role: String
        var languagePreference: String
        var firebaseUID: String?
        var photoData: Data?
        var pinHash: String?
        var pinSalt: String?
        var failedPinAttempts: Int
        var lastModified: Date?
    }
}

// MARK: - Medication, DoseSchedule, DoseLog

extension FirestoreModels {
    struct FMedication: Codable {
        var id: String
        var personID: String
        var name: String
        var dose: String
        var pillsPerDose: Int
        var foodRule: String
        var notes: String?
        var currentSupply: Int
        var pillPhotoData: Data?
        var dateAdded: Date
        var lastModified: Date?
    }

    struct FDoseSchedule: Codable {
        var id: String
        var medicationID: String
        var timeOfDay: String
        var daysOfWeek: Int
        var lastModified: Date?
    }

    struct FDoseLog: Codable {
        var id: String
        var medicationID: String
        var loggedByPersonID: String?
        var scheduledTime: Date
        var actualTime: Date?
        var status: String
        var lastModified: Date?
    }
}

// MARK: - Reserved subcollection shapes (not yet synced)

extension FirestoreModels {
    /// Reserved placeholder from an earlier prompt. Superseded by
    /// `FMedicalID` below — kept around so any legacy doc that landed
    /// in `/careCircles/{id}/medicalProfiles` can still decode without
    /// crashing the listener. The path itself is no longer written by
    /// post-prompt-20 code.
    struct FMedicalProfile: Codable {
        var id: String
        var personID: String
        var allergies: [String]
        var conditions: [String]
        var bloodType: String?
        var emergencyContactName: String?
        var emergencyContactPhone: String?
        var lastModified: Date?
    }

    /// Person-attached medical info supervisors and emergency responders
    /// might need at a glance. One doc per Person at
    /// `/careCircles/{circleID}/people/{personID}/medicalID/{personID}`
    /// — doc id == personID for deterministic addressing.
    ///
    /// Both supervisor flavours can read and edit, intentionally —
    /// any caregiver might need to update info, and emergency
    /// responders care about freshness more than authorship.
    struct FMedicalID: Codable {
        var id: String              // == personID
        var personID: String
        var dateOfBirth: Date?
        var bloodType: String?
        var allergies: [String]
        var conditions: [String]
        var emergencyContacts: [FEmergencyContact]
        var notes: String?
        var updatedAt: Date
    }

    /// Inline value type on FMedicalID. Phone is a free-text field
    /// — no validation, since paramedics need to dial whatever's
    /// there and supervisors may enter shapes like "ext. 4321".
    struct FEmergencyContact: Codable, Hashable {
        var name: String
        var relationship: String
        var phone: String
    }

    /// Supervisor-side alerts inbox. Three types ship right now:
    /// `missedDose`, `emergency`, `weeklySummary`. Each alert is keyed
    /// to a Person; missedDose adds medicationID + scheduledTime, the
    /// rest live in `payload`. The doc id is deterministic for
    /// missedDose and weeklySummary (so concurrent supervisor devices
    /// detecting the same gap converge on a single doc) and a fresh
    /// UUID for emergency.
    ///
    /// The acknowledgement model is "first to ack clears it for
    /// everyone." `acknowledgedBy` is the Firebase UID of whoever ack'd
    /// (nil while pending); `acknowledgedAt` is the server timestamp;
    /// `acknowledgedByName` is denormalized so a device that hasn't
    /// hydrated the supervisor's Person doc can still render
    /// "Acknowledged by …" without an extra lookup.
    struct FAlert: Codable {
        var id: String
        var type: String
        var personID: String
        var medicationID: String?
        var scheduledTime: Date?
        var createdAt: Date
        var payload: [String: String]?
        var acknowledgedBy: String?
        var acknowledgedByName: String?
        var acknowledgedAt: Date?
        var lastModified: Date?
    }

    /// Canonical strings for `FAlert.type`. Kept here so the
    /// generators, the rules, and the views share one source.
    enum AlertType {
        static let missedDose = "missedDose"
        static let emergency = "emergency"
        static let weeklySummary = "weeklySummary"
    }

    /// Reserved for the family-contact list (doctor, pharmacy,
    /// supervising relative not yet on the app).
    struct FFamilyContact: Codable {
        var id: String
        var name: String
        var phone: String?
        var email: String?
        var relationship: String?
        var lastModified: Date?
    }
}

// MARK: - Core Data ↔ Firestore conversion

extension FirestoreModels.FCareCircle {
    init(from circle: CareCircle, supervisorCount: Int) {
        self.id = (circle.id ?? UUID()).uuidString
        self.name = circle.name ?? ""
        self.joinCode = circle.joinCode ?? ""
        self.createdAt = circle.createdAt ?? Date()
        self.supervisorCount = supervisorCount
        self.primarySupervisorPersonID = circle.primarySupervisorPersonID?.uuidString
        self.lastModified = nil
    }

    /// Mirrors `self` onto an existing or newly-created CareCircle row in
    /// `context`. Caller saves the context.
    @discardableResult
    func upsert(in context: NSManagedObjectContext) -> CareCircle? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        let circle = (try? context.fetch(request))?.first ?? CareCircle(context: context)
        circle.id = uuid
        circle.name = name
        circle.joinCode = joinCode
        circle.createdAt = createdAt
        circle.primarySupervisorPersonID = primarySupervisorPersonID.flatMap { UUID(uuidString: $0) }
        return circle
    }
}

extension FirestoreModels.FPerson {
    init(from person: Person, careCircleID: UUID) {
        self.id = (person.id ?? UUID()).uuidString
        self.careCircleID = careCircleID.uuidString
        self.name = person.name ?? ""
        self.role = person.role ?? "device_client"
        self.languagePreference = person.languagePreference ?? "en"
        self.firebaseUID = person.firebaseUID
        self.photoData = person.photoData
        self.pinHash = person.pinHash
        self.pinSalt = person.pinSalt
        self.failedPinAttempts = Int(person.failedPinAttempts)
        self.lastModified = nil
    }

    @discardableResult
    func upsert(in context: NSManagedObjectContext) -> Person? {
        guard let uuid = UUID(uuidString: id),
              let circleUUID = UUID(uuidString: careCircleID) else { return nil }

        let circleRequest = NSFetchRequest<CareCircle>(entityName: "CareCircle")
        circleRequest.predicate = NSPredicate(format: "id == %@", circleUUID as CVarArg)
        circleRequest.fetchLimit = 1
        // The circle should already exist locally — listener attaches
        // /careCircles before /people. If it doesn't, defer the upsert;
        // the next listener fire will catch it.
        guard let circle = (try? context.fetch(circleRequest))?.first else { return nil }

        let request = NSFetchRequest<Person>(entityName: "Person")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        let person = (try? context.fetch(request))?.first ?? Person(context: context)
        person.id = uuid
        person.name = name
        person.role = role
        person.languagePreference = languagePreference
        person.firebaseUID = firebaseUID
        person.photoData = photoData
        person.pinHash = pinHash
        person.pinSalt = pinSalt
        person.failedPinAttempts = Int16(min(Int(Int16.max), failedPinAttempts))
        person.careCircle = circle
        return person
    }
}

extension FirestoreModels.FMedication {
    init(from med: Medication) {
        self.id = (med.id ?? UUID()).uuidString
        self.personID = (med.personID ?? UUID()).uuidString
        self.name = med.name ?? ""
        self.dose = med.dose ?? ""
        self.pillsPerDose = Int(med.pillsPerDose)
        self.foodRule = med.foodRule ?? "either"
        self.notes = med.notes
        self.currentSupply = Int(med.currentSupply)
        self.pillPhotoData = med.pillPhotoData
        self.dateAdded = med.dateAdded ?? Date()
        self.lastModified = nil
    }

    @discardableResult
    func upsert(in context: NSManagedObjectContext) -> Medication? {
        guard let uuid = UUID(uuidString: id),
              let personUUID = UUID(uuidString: personID) else { return nil }
        let request = NSFetchRequest<Medication>(entityName: "Medication")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        let med = (try? context.fetch(request))?.first ?? Medication(context: context)
        med.id = uuid
        med.personID = personUUID
        med.name = name
        med.dose = dose
        med.pillsPerDose = Int16(min(Int(Int16.max), pillsPerDose))
        med.foodRule = foodRule
        med.notes = notes
        med.currentSupply = Int16(min(Int(Int16.max), currentSupply))
        med.pillPhotoData = pillPhotoData
        med.dateAdded = dateAdded
        return med
    }
}

extension FirestoreModels.FDoseSchedule {
    init(from schedule: DoseSchedule) {
        self.id = (schedule.id ?? UUID()).uuidString
        self.medicationID = (schedule.medication?.id ?? UUID()).uuidString
        self.timeOfDay = schedule.timeOfDay ?? "08:00"
        self.daysOfWeek = Int(schedule.daysOfWeek)
        self.lastModified = nil
    }

    @discardableResult
    func upsert(in context: NSManagedObjectContext) -> DoseSchedule? {
        guard let uuid = UUID(uuidString: id),
              let medUUID = UUID(uuidString: medicationID) else { return nil }

        let medRequest = NSFetchRequest<Medication>(entityName: "Medication")
        medRequest.predicate = NSPredicate(format: "id == %@", medUUID as CVarArg)
        medRequest.fetchLimit = 1
        guard let med = (try? context.fetch(medRequest))?.first else { return nil }

        let request = NSFetchRequest<DoseSchedule>(entityName: "DoseSchedule")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        let schedule = (try? context.fetch(request))?.first ?? DoseSchedule(context: context)
        schedule.id = uuid
        schedule.timeOfDay = timeOfDay
        schedule.daysOfWeek = Int16(min(Int(Int16.max), daysOfWeek))
        schedule.medication = med
        return schedule
    }
}

extension FirestoreModels.FDoseLog {
    init(from log: DoseLog) {
        self.id = (log.id ?? UUID()).uuidString
        self.medicationID = (log.medication?.id ?? UUID()).uuidString
        self.loggedByPersonID = log.loggedByPersonID?.uuidString
        self.scheduledTime = log.scheduledTime ?? Date()
        self.actualTime = log.actualTime
        self.status = log.status ?? "upcoming"
        self.lastModified = nil
    }

    @discardableResult
    func upsert(in context: NSManagedObjectContext) -> DoseLog? {
        guard let uuid = UUID(uuidString: id),
              let medUUID = UUID(uuidString: medicationID) else { return nil }

        let medRequest = NSFetchRequest<Medication>(entityName: "Medication")
        medRequest.predicate = NSPredicate(format: "id == %@", medUUID as CVarArg)
        medRequest.fetchLimit = 1
        guard let med = (try? context.fetch(medRequest))?.first else { return nil }

        let request = NSFetchRequest<DoseLog>(entityName: "DoseLog")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        let log = (try? context.fetch(request))?.first ?? DoseLog(context: context)
        log.id = uuid
        log.medication = med
        log.loggedByPersonID = loggedByPersonID.flatMap { UUID(uuidString: $0) }
        log.scheduledTime = scheduledTime
        log.actualTime = actualTime
        log.status = status
        return log
    }
}

extension FirestoreModels.FAlert {
    init(from alert: Alert, careCircleID: UUID) {
        self.id = alert.docID ?? UUID().uuidString
        self.type = alert.type ?? FirestoreModels.AlertType.missedDose
        self.personID = (alert.personID ?? UUID()).uuidString
        self.medicationID = alert.medicationID?.uuidString
        self.scheduledTime = alert.scheduledTime
        self.createdAt = alert.createdAt ?? Date()
        self.payload = FirestoreModels.FAlert.decodePayload(alert.payloadJSON)
        self.acknowledgedBy = alert.acknowledgedByFirebaseUID
        self.acknowledgedByName = alert.acknowledgedByName
        self.acknowledgedAt = alert.acknowledgedAt
        self.lastModified = nil
    }

    @discardableResult
    func upsert(in context: NSManagedObjectContext, careCircleID: UUID) -> Alert? {
        let circleRequest = NSFetchRequest<CareCircle>(entityName: "CareCircle")
        circleRequest.predicate = NSPredicate(format: "id == %@", careCircleID as CVarArg)
        circleRequest.fetchLimit = 1
        guard let circle = (try? context.fetch(circleRequest))?.first else { return nil }
        guard let personUUID = UUID(uuidString: personID) else { return nil }

        let request = NSFetchRequest<Alert>(entityName: "Alert")
        request.predicate = NSPredicate(format: "docID == %@", id)
        request.fetchLimit = 1
        let alert = (try? context.fetch(request))?.first ?? Alert(context: context)
        alert.docID = id
        alert.type = type
        alert.personID = personUUID
        alert.medicationID = medicationID.flatMap { UUID(uuidString: $0) }
        alert.scheduledTime = scheduledTime
        alert.createdAt = createdAt
        alert.payloadJSON = FirestoreModels.FAlert.encodePayload(payload)
        alert.acknowledgedByFirebaseUID = acknowledgedBy
        alert.acknowledgedByName = acknowledgedByName
        alert.acknowledgedAt = acknowledgedAt
        alert.careCircle = circle
        return alert
    }

    static func encodePayload(_ payload: [String: String]?) -> String? {
        guard let payload, !payload.isEmpty,
              let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodePayload(_ json: String?) -> [String: String]? {
        guard let json, let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return map
    }
}

extension FirestoreModels.FMedicalID {
    init(from local: MedicalID) {
        let personUUID = local.personID ?? UUID()
        self.id = personUUID.uuidString
        self.personID = personUUID.uuidString
        self.dateOfBirth = local.dateOfBirth
        self.bloodType = local.bloodType
        self.allergies = FirestoreModels.FMedicalID.decodeStringList(local.allergiesJSON)
        self.conditions = FirestoreModels.FMedicalID.decodeStringList(local.conditionsJSON)
        self.emergencyContacts = FirestoreModels.FMedicalID.decodeContacts(local.emergencyContactsJSON)
        self.notes = local.notes
        self.updatedAt = local.updatedAt ?? Date()
    }

    /// Upsert into the view context. Looks up an existing MedicalID
    /// by personID, otherwise inserts. Resolves the Person row by id
    /// — without that link the inverse relationship is dead weight.
    @discardableResult
    func upsert(in context: NSManagedObjectContext) -> MedicalID? {
        guard let uuid = UUID(uuidString: personID) else { return nil }

        let personRequest = NSFetchRequest<Person>(entityName: "Person")
        personRequest.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        personRequest.fetchLimit = 1
        let person = (try? context.fetch(personRequest))?.first

        let request = NSFetchRequest<MedicalID>(entityName: "MedicalID")
        request.predicate = NSPredicate(format: "personID == %@", uuid as CVarArg)
        request.fetchLimit = 1
        let row = (try? context.fetch(request))?.first ?? MedicalID(context: context)
        row.personID = uuid
        row.dateOfBirth = dateOfBirth
        row.bloodType = bloodType
        row.allergiesJSON = FirestoreModels.FMedicalID.encodeStringList(allergies)
        row.conditionsJSON = FirestoreModels.FMedicalID.encodeStringList(conditions)
        row.emergencyContactsJSON = FirestoreModels.FMedicalID.encodeContacts(emergencyContacts)
        row.notes = notes
        row.updatedAt = updatedAt
        row.person = person
        return row
    }

    // MARK: - JSON encode/decode for the three list-shaped fields

    static func encodeStringList(_ values: [String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeStringList(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }

    static func encodeContacts(_ values: [FirestoreModels.FEmergencyContact]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeContacts(_ json: String?) -> [FirestoreModels.FEmergencyContact] {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([FirestoreModels.FEmergencyContact].self, from: data) else {
            return []
        }
        return values
    }
}

/// Helpers that mint the deterministic doc id for the two idempotent
/// alert kinds. Consolidated so generators, repository methods, and
/// tests all derive the same string from the same inputs.
enum AlertID {
    /// `missed-{personID}-{medicationID}-{epochMillis}` — concurrent
    /// supervisor devices detecting the same missed dose all try to
    /// write this exact doc, and Firestore's `setData(merge: false)`
    /// (via `createIfAbsent`) ensures only the first lands.
    static func missedDose(personID: UUID, medicationID: UUID, scheduledTime: Date) -> String {
        let epoch = Int(scheduledTime.timeIntervalSince1970 * 1000)
        return "missed-\(personID.uuidString)-\(medicationID.uuidString)-\(epoch)"
    }

    /// `weekly-{circleID}-{ISODateOfTheSundayThatEndsTheWeek}` — same
    /// idempotency story, scoped to the circle. Two devices both
    /// generating Sunday's summary write the same doc id; only one
    /// commits.
    static func weeklySummary(circleID: UUID, weekEndingSunday: Date,
                              calendar: Calendar = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let day = calendar.startOfDay(for: weekEndingSunday)
        return "weekly-\(circleID.uuidString)-\(formatter.string(from: day))"
    }
}
