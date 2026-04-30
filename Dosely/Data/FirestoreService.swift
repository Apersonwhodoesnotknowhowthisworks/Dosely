import FirebaseCore
import FirebaseFirestore
import Foundation

enum FirestoreServiceError: Error, Equatable {
    /// We're offline and the SDK couldn't reach the server. Acceptable —
    /// the SDK queues the write and replays it on reconnect.
    case offline
    /// Security rules rejected the write. Surface to the UI; this
    /// indicates a permission boundary, not a transient failure.
    case permissionDenied
    /// The document doesn't exist. Typically a join code that has been
    /// regenerated.
    case notFound
    /// Anything we don't classify. Wraps the underlying domain/code as a
    /// debug string for logs.
    case unknown(String)

    static func map(_ error: Error) -> FirestoreServiceError {
        let ns = error as NSError
        if ns.domain == FirestoreErrorDomain {
            switch ns.code {
            case FirestoreErrorCode.unavailable.rawValue:
                return .offline
            case FirestoreErrorCode.permissionDenied.rawValue:
                return .permissionDenied
            case FirestoreErrorCode.notFound.rawValue:
                return .notFound
            default:
                return .unknown("FirestoreError(\(ns.code)): \(ns.localizedDescription)")
            }
        }
        return .unknown("\(ns.domain)(\(ns.code)): \(ns.localizedDescription)")
    }
}

/// Wrapper around the Firestore client. All shared family data flows
/// through here; the repositories call into FirestoreService and then
/// mirror the result into Core Data.
///
/// Tolerates "Firebase not configured" silently — the lazy `shared`
/// initializer checks `FirebaseApp.app()` and falls back to a no-op
/// instance whose methods complete without I/O. This lets the existing
/// Core Data-only tests construct repositories without first wiring up
/// Firebase. Production code (DoselyApp) calls `FirebaseApp.configure()`
/// before any repository is built, so the real path is always taken.
final class FirestoreService {
    static let shared: FirestoreService = {
        if FirebaseApp.app() != nil {
            return FirestoreService(db: Firestore.firestore())
        }
        return FirestoreService()
    }()

    let db: Firestore?
    var isConfigured: Bool { db != nil }

    init() { self.db = nil }

    init(db: Firestore) { self.db = db }

    // MARK: - Emulator

    /// Points the SDK at a local Firebase emulator. Tests call this in
    /// setUp; production code never does.
    static func useEmulator(host: String = "127.0.0.1", port: Int = 8080) -> FirestoreService {
        let settings = FirestoreSettings()
        settings.host = "\(host):\(port)"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        let db = Firestore.firestore()
        db.settings = settings
        return FirestoreService(db: db)
    }

    // MARK: - Collection paths

    enum Path {
        static let careCircles = "careCircles"
        static let joinCodes = "joinCodes"
        static let userMemberships = "userMemberships"

        static func careCircle(_ id: String) -> String { "\(careCircles)/\(id)" }
        static func people(_ circleID: String) -> String { "\(careCircle(circleID))/people" }
        static func medications(_ circleID: String) -> String { "\(careCircle(circleID))/medications" }
        static func doseSchedules(_ circleID: String) -> String { "\(careCircle(circleID))/doseSchedules" }
        static func doseLogs(_ circleID: String) -> String { "\(careCircle(circleID))/doseLogs" }
        static func medicalProfiles(_ circleID: String) -> String { "\(careCircle(circleID))/medicalProfiles" }
        static func alerts(_ circleID: String) -> String { "\(careCircle(circleID))/alerts" }
        static func familyContacts(_ circleID: String) -> String { "\(careCircle(circleID))/familyContacts" }
        static func userMembership(_ firebaseUID: String) -> String { "\(userMemberships)/\(firebaseUID)" }
    }

    // MARK: - Generic helpers

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        try Firestore.Encoder().encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from snapshot: DocumentSnapshot) throws -> T {
        try snapshot.data(as: type)
    }

    // MARK: - Care circle / join code

    /// Creates `/careCircles/{id}` (with supervisorCount=0) and
    /// `/joinCodes/{code}` in a single batch so the reverse lookup never
    /// points at a missing circle. The caller is expected to write the
    /// founding supervisor's `/userMemberships` and `/people` docs next,
    /// then call `incrementSupervisorCount` to flip the count to 1 — the
    /// rules layer requires count==0 during /userMemberships founder
    /// bootstrap.
    func createCareCircle(_ circle: FirestoreModels.FCareCircle) async throws {
        guard let db else { return }
        var seed = circle
        seed.supervisorCount = 0
        let batch = db.batch()
        let circleRef = db.document(Path.careCircle(seed.id))
        let codeRef = db.document("\(Path.joinCodes)/\(seed.joinCode)")
        do {
            var payload = try encode(seed)
            payload["lastModified"] = FieldValue.serverTimestamp()
            batch.setData(payload, forDocument: circleRef)
            let index = FirestoreModels.FJoinCodeIndex(careCircleID: seed.id, regeneratedAt: Date())
            batch.setData(try encode(index), forDocument: codeRef)
            try await batch.commit()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    // MARK: - User membership index

    /// Writes `/userMemberships/{firebaseUID}`. Used at create-circle
    /// (founder), join-circle (joiner — pass joinCode), and supervisor-
    /// adds-client paths.
    func upsertMembership(
        firebaseUID: String,
        membership: FirestoreModels.FUserMembership
    ) async throws {
        guard let db else { return }
        do {
            let payload = try encode(membership)
            try await db.document(Path.userMembership(firebaseUID)).setData(payload)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    func deleteMembership(firebaseUID: String) async throws {
        guard let db else { return }
        do {
            try await db.document(Path.userMembership(firebaseUID)).delete()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Bumps `careCircles/{id}.supervisorCount` by `delta`. Pass +1 when a
    /// supervisor is added (createCareCircle / joinCareCircle), -1 when a
    /// supervisor leaves or is removed. Decrement is the second half of
    /// the leave-batch — see `removeSupervisorAtomically`.
    func adjustSupervisorCount(circleID: String, delta: Int) async throws {
        guard let db else { return }
        do {
            try await db.document(Path.careCircle(circleID)).updateData([
                "supervisorCount": FieldValue.increment(Int64(delta)),
                "lastModified": FieldValue.serverTimestamp()
            ])
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Atomically declares `newPrimaryPersonID` the primary supervisor
    /// of the circle. In one batch:
    ///
    /// - sets `careCircles/{id}.primarySupervisorPersonID = newPrimaryPersonID`
    /// - for each supervisor in `supervisors`, writes `role` on their
    ///   `Person` doc: the one whose `personID == newPrimaryPersonID`
    ///   becomes `primary_supervisor`, everyone else becomes
    ///   `secondary_supervisor`
    /// - for each supervisor that has a `firebaseUID`, mirrors the role
    ///   onto their `/userMemberships/{uid}` doc
    ///
    /// Used by both `PrimaryRoleMigration` (ALL supervisors at once,
    /// converting legacy "supervisor" rows) and `promoteToPrimary` (the
    /// current primary + target pair). The Firestore rules' `isPromotionBatch`
    /// helper recognizes this exact write shape — see firestore.rules.
    func applyPrimaryAssignment(
        circleID: String,
        newPrimaryPersonID: String,
        supervisors: [(personID: String, firebaseUID: String?)]
    ) async throws {
        guard let db else { return }
        do {
            let batch = db.batch()
            let circleRef = db.document(Path.careCircle(circleID))
            batch.updateData([
                "primarySupervisorPersonID": newPrimaryPersonID,
                "lastModified": FieldValue.serverTimestamp()
            ], forDocument: circleRef)

            for entry in supervisors {
                let role = entry.personID == newPrimaryPersonID
                    ? "primary_supervisor"
                    : "secondary_supervisor"
                let personRef = db
                    .collection(Path.people(circleID))
                    .document(entry.personID)
                batch.updateData([
                    "role": role,
                    "lastModified": FieldValue.serverTimestamp()
                ], forDocument: personRef)
                if let uid = entry.firebaseUID {
                    let membershipRef = db.document(Path.userMembership(uid))
                    batch.updateData([
                        "role": role
                    ], forDocument: membershipRef)
                }
            }

            try await batch.commit()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Atomically removes a supervisor: deletes their Person doc,
    /// decrements `supervisorCount` on the parent circle, and (if a
    /// Firebase UID is provided) deletes their `/userMemberships` doc.
    /// All three writes commit together so the rules-layer
    /// last-supervisor protection (post-batch supervisorCount >= 1) sees
    /// a consistent state.
    func removeSupervisorAtomically(
        circleID: String,
        personID: String,
        firebaseUID: String?
    ) async throws {
        guard let db else { return }
        do {
            let batch = db.batch()
            let personRef = db.document("\(Path.people(circleID))/\(personID)")
            let circleRef = db.document(Path.careCircle(circleID))
            batch.deleteDocument(personRef)
            batch.updateData([
                "supervisorCount": FieldValue.increment(Int64(-1)),
                "lastModified": FieldValue.serverTimestamp()
            ], forDocument: circleRef)
            if let uid = firebaseUID {
                batch.deleteDocument(db.document(Path.userMembership(uid)))
            }
            try await batch.commit()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Updates a circle document. Used for `renameCircle`. Does not
    /// touch `joinCodes` — call `regenerateJoinCode` for that.
    func updateCareCircleName(circleID: String, newName: String) async throws {
        guard let db else { return }
        do {
            try await db.document(Path.careCircle(circleID)).updateData([
                "name": newName,
                "lastModified": FieldValue.serverTimestamp()
            ])
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    func loadCareCircle(circleID: String) async throws -> FirestoreModels.FCareCircle? {
        guard let db else { return nil }
        do {
            let snap = try await db.document(Path.careCircle(circleID)).getDocument()
            guard snap.exists else { return nil }
            return try decode(FirestoreModels.FCareCircle.self, from: snap)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Looks up a join code via `/joinCodes/{code}` (a direct document
    /// fetch, not a collection scan). Returns the `FCareCircle` document
    /// if both lookups succeed, else nil. When Firebase isn't
    /// configured, throws `.offline` so callers fall back to their
    /// Core Data path rather than treating the service as authoritative.
    func lookupJoinCode(_ code: String) async throws -> FirestoreModels.FCareCircle? {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let codeSnap = try await db.document("\(Path.joinCodes)/\(code)").getDocument()
            guard codeSnap.exists else { return nil }
            let index = try decode(FirestoreModels.FJoinCodeIndex.self, from: codeSnap)
            return try await loadCareCircle(circleID: index.careCircleID)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Atomically swaps the join code for a circle:
    /// - delete `/joinCodes/{old}`
    /// - create `/joinCodes/{new}`
    /// - update `/careCircles/{id}.joinCode = new`
    /// All three happen in one Firestore transaction.
    func regenerateJoinCode(circleID: String, oldCode: String, newCode: String) async throws {
        guard let db else { return }
        do {
            _ = try await db.runTransaction({ (txn, errorPointer) -> Any? in
                let circleRef = db.document(Path.careCircle(circleID))
                let oldCodeRef = db.document("\(Path.joinCodes)/\(oldCode)")
                let newCodeRef = db.document("\(Path.joinCodes)/\(newCode)")

                txn.updateData([
                    "joinCode": newCode,
                    "lastModified": FieldValue.serverTimestamp()
                ], forDocument: circleRef)
                txn.deleteDocument(oldCodeRef)
                do {
                    let index = FirestoreModels.FJoinCodeIndex(
                        careCircleID: circleID,
                        regeneratedAt: Date()
                    )
                    let payload = try Firestore.Encoder().encode(index)
                    txn.setData(payload, forDocument: newCodeRef)
                } catch let error as NSError {
                    errorPointer?.pointee = error
                    return nil
                }
                return nil
            })
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    // MARK: - Person

    func upsertPerson(_ person: FirestoreModels.FPerson) async throws {
        guard let db else { return }
        do {
            var payload = try encode(person)
            payload["lastModified"] = FieldValue.serverTimestamp()
            try await db
                .collection(Path.people(person.careCircleID))
                .document(person.id)
                .setData(payload)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    func deletePerson(circleID: String, personID: String) async throws {
        guard let db else { return }
        do {
            try await db.collection(Path.people(circleID)).document(personID).delete()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    func fetchPeople(circleID: String) async throws -> [FirestoreModels.FPerson] {
        guard let db else { return [] }
        do {
            let snap = try await db.collection(Path.people(circleID)).getDocuments()
            return snap.documents.compactMap { try? $0.data(as: FirestoreModels.FPerson.self) }
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    // MARK: - Medication

    func upsertMedication(circleID: String, med: FirestoreModels.FMedication) async throws {
        guard let db else { return }
        do {
            var payload = try encode(med)
            payload["lastModified"] = FieldValue.serverTimestamp()
            try await db
                .collection(Path.medications(circleID))
                .document(med.id)
                .setData(payload)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    func deleteMedication(circleID: String, medicationID: String) async throws {
        guard let db else { return }
        do {
            // Cascade: delete schedules + logs that reference this med.
            // Firestore has no FK cascade so we do it client-side.
            let schedules = try await db
                .collection(Path.doseSchedules(circleID))
                .whereField("medicationID", isEqualTo: medicationID)
                .getDocuments()
            let logs = try await db
                .collection(Path.doseLogs(circleID))
                .whereField("medicationID", isEqualTo: medicationID)
                .getDocuments()

            let batch = db.batch()
            for doc in schedules.documents { batch.deleteDocument(doc.reference) }
            for doc in logs.documents { batch.deleteDocument(doc.reference) }
            batch.deleteDocument(
                db.collection(Path.medications(circleID)).document(medicationID)
            )
            try await batch.commit()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    // MARK: - DoseSchedule

    func upsertSchedule(circleID: String, schedule: FirestoreModels.FDoseSchedule) async throws {
        guard let db else { return }
        do {
            var payload = try encode(schedule)
            payload["lastModified"] = FieldValue.serverTimestamp()
            try await db
                .collection(Path.doseSchedules(circleID))
                .document(schedule.id)
                .setData(payload)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Replaces every schedule for a medication with the given set, in
    /// one batch. Mirrors the Core Data behaviour of `replaceSchedules`.
    func replaceSchedules(
        circleID: String,
        medicationID: String,
        schedules: [FirestoreModels.FDoseSchedule]
    ) async throws {
        guard let db else { return }
        do {
            let existing = try await db
                .collection(Path.doseSchedules(circleID))
                .whereField("medicationID", isEqualTo: medicationID)
                .getDocuments()

            let batch = db.batch()
            for doc in existing.documents { batch.deleteDocument(doc.reference) }
            for schedule in schedules {
                var payload = try encode(schedule)
                payload["lastModified"] = FieldValue.serverTimestamp()
                let ref = db.collection(Path.doseSchedules(circleID)).document(schedule.id)
                batch.setData(payload, forDocument: ref)
            }
            try await batch.commit()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    func deleteSchedule(circleID: String, scheduleID: String) async throws {
        guard let db else { return }
        do {
            try await db
                .collection(Path.doseSchedules(circleID))
                .document(scheduleID)
                .delete()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    // MARK: - DoseLog

    func upsertDoseLog(circleID: String, log: FirestoreModels.FDoseLog) async throws {
        guard let db else { return }
        do {
            var payload = try encode(log)
            payload["lastModified"] = FieldValue.serverTimestamp()
            try await db
                .collection(Path.doseLogs(circleID))
                .document(log.id)
                .setData(payload)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    // MARK: - Listener registration

    /// Generic listener — observes a collection and decodes each
    /// document, calling `onChange` with the latest list. Caller retains
    /// the returned `ListenerRegistration` and removes it on tear-down.
    /// When Firebase isn't configured (test path), returns a no-op.
    @discardableResult
    func listen<T: Decodable>(
        collectionPath: String,
        as type: T.Type,
        onChange: @escaping ([T]) -> Void
    ) -> ListenerRegistration {
        guard let db else { return NoOpListener() }
        return db.collection(collectionPath).addSnapshotListener { snapshot, _ in
            guard let documents = snapshot?.documents else {
                onChange([])
                return
            }
            let decoded = documents.compactMap { try? $0.data(as: T.self) }
            onChange(decoded)
        }
    }

    /// Same as `listen(...)` but for a single document. Used for the
    /// CareCircle root document.
    @discardableResult
    func listenDocument<T: Decodable>(
        documentPath: String,
        as type: T.Type,
        onChange: @escaping (T?) -> Void
    ) -> ListenerRegistration {
        guard let db else { return NoOpListener() }
        return db.document(documentPath).addSnapshotListener { snapshot, _ in
            guard let snapshot, snapshot.exists else {
                onChange(nil)
                return
            }
            onChange(try? snapshot.data(as: T.self))
        }
    }
}

/// Stand-in returned from `listen(...)` when Firebase isn't
/// configured. `remove()` is a no-op so SyncCoordinator's tear-down
/// does the right thing without special-casing nil.
private final class NoOpListener: NSObject, ListenerRegistration {
    func remove() {}
}
