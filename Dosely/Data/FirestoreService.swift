import FirebaseCore
import FirebaseFirestore
import Foundation
import OSLog

/// The four error shapes every Firestore round-trip can produce.
///
/// **Project-wide convention** (see build_log April 30 — "Phantom
/// join code bug" and May 13 — "Medical ID save permission denied"):
/// repositories MUST surface these distinct cases up to the UI, never
/// collapsing `.permissionDenied` into `.offline` or vice versa. A
/// connection-error message on a rules rejection sends supervisors
/// chasing the wrong cause. The mapping happens here once; every
/// caller is responsible for branching on the case.
enum FirestoreServiceError: Error, Equatable {
    /// The SDK couldn't reach the server. Network-level failure or
    /// the SDK isn't configured. Acceptable to retry, and the SDK
    /// queues writes locally where possible.
    case offline
    /// Security rules rejected the write. Surface to the UI as
    /// "you don't have access" — NEVER as "check your connection."
    case permissionDenied
    /// The document doesn't exist. Typically a join code that has
    /// been regenerated or a doc that was deleted.
    case notFound
    /// Anything we don't classify. The string carries the domain/code
    /// for diagnostics; `os_log` records it at map-time so a future
    /// "what tripped this" investigation doesn't need Xcode attached.
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
                let detail = "FirestoreError(\(ns.code)): \(ns.localizedDescription)"
                Self.logger.error("Unmapped Firestore error: \(detail, privacy: .public)")
                return .unknown(detail)
            }
        }
        let detail = "\(ns.domain)(\(ns.code)): \(ns.localizedDescription)"
        Self.logger.error("Unmapped error from Firestore call: \(detail, privacy: .public)")
        return .unknown(detail)
    }

    private static let logger = Logger(subsystem: "com.medication.dosely", category: "firestore")
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
    ///
    /// **Idempotent.** `Firestore.firestore()` is a process-wide SDK
    /// singleton, and `db.settings = ...` only succeeds *before* the
    /// first operation on that singleton. Once any test has done a
    /// read or write, the settings are frozen and re-assigning throws
    /// `FIRIllegalStateException`. We cache the configured service on
    /// the first call and return it for every subsequent setUp so
    /// later tests don't crash trying to re-set the emulator host.
    private static var cachedEmulatorService: FirestoreService?

    static func useEmulator(host: String = "127.0.0.1", port: Int = 8080) -> FirestoreService {
        if let cached = cachedEmulatorService { return cached }
        let settings = FirestoreSettings()
        settings.host = "\(host):\(port)"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        let db = Firestore.firestore()
        db.settings = settings
        let service = FirestoreService(db: db)
        cachedEmulatorService = service
        return service
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
        /// `/careCircles/{circleID}/people/{personID}/medicalID/{personID}`
        /// — nested under the person doc; doc id == personID for
        /// deterministic addressing.
        static func medicalID(_ circleID: String, personID: String) -> String {
            "\(people(circleID))/\(personID)/medicalID/\(personID)"
        }
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

    /// Fetches `/userMemberships/{firebaseUID}`. Returns nil when the
    /// doc doesn't exist (brand-new user, or membership lost on a wipe).
    /// Throws `.offline` when Firebase isn't configured or the network
    /// is unreachable so the caller can distinguish "no membership"
    /// from "couldn't ask" — the membership-first sign-in path needs
    /// that distinction to avoid misclassifying offline users as new.
    func fetchMembership(
        firebaseUID: String
    ) async throws -> FirestoreModels.FUserMembership? {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db.document(Path.userMembership(firebaseUID)).getDocument()
            guard snap.exists else { return nil }
            return try decode(FirestoreModels.FUserMembership.self, from: snap)
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

    /// Backfills (or refreshes) a `/userMemberships/{uid}` doc for the
    /// caller. Used as PHASE A of `PrimaryRoleMigration` on devices
    /// whose membership index doc was lost — without it, the rules'
    /// `isPrimary` check fails (it requires a /userMemberships to look
    /// up the Person doc), which blocks the migration's atomic batch.
    /// `setData(merge: true)` creates the doc if missing (Firestore
    /// rules' membership create branch (d) allows this when a Person
    /// doc with matching firebaseUID + supervisor role already exists)
    /// and updates the role on an existing doc.
    func ensureMembership(
        circleID: String,
        firebaseUID: String,
        personID: String,
        role: String
    ) async throws {
        guard let db else { return }
        do {
            try await db.document(Path.userMembership(firebaseUID)).setData([
                "careCircleID": circleID,
                "personID": personID,
                "role": role,
                "joinedAt": FieldValue.serverTimestamp()
            ], merge: true)
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
    ///   onto their `/userMemberships/{uid}` doc. The membership write
    ///   uses `setData(merge: true)` with the full membership shape
    ///   (careCircleID, personID, role, joinedAt) so it self-heals
    ///   missing index docs — production data from earlier app versions
    ///   sometimes has a Person row without a corresponding
    ///   /userMemberships, which would lock the supervisor out under
    ///   the new role-aware rules. The Firestore rules' membership
    ///   create-rule branch (d) "self-backfill" recognizes this case.
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
        Self.roleLogger.debug(
            "applyPrimaryAssignment: batch starting circle=\(circleID, privacy: .public) newPrimary=\(newPrimaryPersonID, privacy: .public) supervisorRows=\(supervisors.count, privacy: .public)"
        )
        do {
            let batch = db.batch()
            let circleRef = db.document(Path.careCircle(circleID))
            batch.updateData([
                "primarySupervisorPersonID": newPrimaryPersonID,
                "lastModified": FieldValue.serverTimestamp()
            ], forDocument: circleRef)
            Self.roleLogger.debug("applyPrimaryAssignment: write circle.primarySupervisorPersonID circle=\(circleID, privacy: .public)")

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
                Self.roleLogger.debug(
                    "applyPrimaryAssignment: write person.role personID=\(entry.personID, privacy: .public) role=\(role, privacy: .public)"
                )
                if let uid = entry.firebaseUID {
                    let membershipRef = db.document(Path.userMembership(uid))
                    // setData(merge: true): updates `role` on an existing
                    // membership; creates the full doc if missing. The
                    // careCircleID / personID / joinedAt fields satisfy
                    // the rules' validation either way (membership update
                    // ignores them; membership create requires them).
                    batch.setData([
                        "careCircleID": circleID,
                        "personID": entry.personID,
                        "role": role,
                        "joinedAt": FieldValue.serverTimestamp()
                    ], forDocument: membershipRef, merge: true)
                    Self.roleLogger.debug(
                        "applyPrimaryAssignment: write membership.role uid=\(uid, privacy: .public) role=\(role, privacy: .public)"
                    )
                }
            }

            try await batch.commit()
            Self.roleLogger.info("applyPrimaryAssignment: success circle=\(circleID, privacy: .public) newPrimary=\(newPrimaryPersonID, privacy: .public)")
        } catch {
            let ns = error as NSError
            Self.roleLogger.error(
                "applyPrimaryAssignment: batch failed circle=\(circleID, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public)"
            )
            // Distinct error codes per error-collapse convention —
            // see build_log April 30 phantom join code entry.
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

    /// Resolves a join code to a careCircle id via `/joinCodes/{code}`
    /// (a direct document fetch — readable by any signed-in user, by
    /// design, so a joiner can find the circle they're about to join).
    /// Returns the `careCircleID` on hit, nil if the code is unknown.
    /// When Firebase isn't configured, throws `.offline` so callers
    /// fall back to their Core Data path.
    ///
    /// **Does NOT read `/careCircles/{id}`.** That read requires
    /// `memberOf(circleID)`, which a brand-new joiner cannot satisfy
    /// before their `/userMemberships` doc is written. Loading the
    /// careCircle inside this lookup was the source of the join-flow
    /// permission-denied that the UI was misreporting as "code not
    /// found." Callers that need the full circle doc must call
    /// `loadCareCircle` themselves *after* the membership write.
    func lookupJoinCode(_ code: String) async throws -> String? {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let codeSnap = try await db.document("\(Path.joinCodes)/\(code)").getDocument()
            guard codeSnap.exists else { return nil }
            let index = try decode(FirestoreModels.FJoinCodeIndex.self, from: codeSnap)
            return index.careCircleID
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Atomic joiner-bootstrap. In a single Firestore batch:
    /// - creates `/userMemberships/{firebaseUID}` (with the joinCode
    ///   that satisfies the rules' branch (b) authority check),
    /// - creates `/careCircles/{circleID}/people/{personID}` with role
    ///   `secondary_supervisor`,
    /// - increments `/careCircles/{circleID}.supervisorCount` by 1.
    ///
    /// All three writes commit together. The Person create rule's
    /// `existsAfter(/userMemberships/{auth.uid})` and the careCircle
    /// update rule's joiner-bootstrap branch both evaluate against the
    /// post-batch state where the membership doc exists with
    /// `careCircleID == circleID`, so each row's rule passes.
    ///
    /// Throws `.permissionDenied` when the rules reject the batch
    /// (typically a stale or wrong join code), `.offline` when the
    /// network's down, `.unknown` for everything else.
    func joinCircleAsSecondary(
        circleID: String,
        firebaseUID: String,
        personID: String,
        name: String,
        language: String,
        joinCode: String
    ) async throws {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let membership = FirestoreModels.FUserMembership(
                careCircleID: circleID,
                personID: personID,
                role: Roles.secondarySupervisor,
                joinedAt: Date(),
                joinCode: joinCode
            )
            let person = FirestoreModels.FPerson(
                id: personID,
                careCircleID: circleID,
                name: name,
                role: Roles.secondarySupervisor,
                languagePreference: language,
                firebaseUID: firebaseUID,
                photoData: nil,
                pinHash: nil,
                pinSalt: nil,
                failedPinAttempts: 0,
                lastModified: nil
            )
            var membershipPayload = try encode(membership)
            membershipPayload["joinedAt"] = FieldValue.serverTimestamp()
            var personPayload = try encode(person)
            personPayload["lastModified"] = FieldValue.serverTimestamp()

            let batch = db.batch()
            batch.setData(
                membershipPayload,
                forDocument: db.document(Path.userMembership(firebaseUID))
            )
            batch.setData(
                personPayload,
                forDocument: db
                    .collection(Path.people(circleID))
                    .document(personID)
            )
            batch.updateData([
                "supervisorCount": FieldValue.increment(Int64(1)),
                "lastModified": FieldValue.serverTimestamp()
            ], forDocument: db.document(Path.careCircle(circleID)))
            #if DEBUG
            print("[JOIN-DEBUG] batch.commit circle=\(circleID) joiner=\(firebaseUID) personID=\(personID)")
            #endif
            try await batch.commit()
            #if DEBUG
            print("[JOIN-DEBUG] commit succeeded for joiner=\(firebaseUID)")
            #endif
        } catch {
            #if DEBUG
            let ns = error as NSError
            print("[JOIN-DEBUG] commit threw: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
            #endif
            throw FirestoreServiceError.map(error)
        }
    }

    /// Atomically swaps the join code for a circle:
    /// - delete `/joinCodes/{old}`
    /// - create `/joinCodes/{new}`
    /// - update `/careCircles/{id}.joinCode = new`
    /// All three commit together via a single `WriteBatch` so the
    /// reverse-lookup index never points at a stale code. (We use a
    /// `WriteBatch` rather than `runTransaction` because the swap has no
    /// reads — a pure-write transaction is a degenerate shape that has
    /// historically returned success without committing on this path.)
    /// Throws `FirestoreServiceError.offline` when Firebase isn't
    /// configured or the network is unreachable so callers don't update
    /// local state with a code that never reached the server.
    func regenerateJoinCode(circleID: String, oldCode: String, newCode: String) async throws {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let batch = db.batch()
            let circleRef = db.document(Path.careCircle(circleID))
            let oldCodeRef = db.document("\(Path.joinCodes)/\(oldCode)")
            let newCodeRef = db.document("\(Path.joinCodes)/\(newCode)")

            batch.updateData([
                "joinCode": newCode,
                "lastModified": FieldValue.serverTimestamp()
            ], forDocument: circleRef)
            batch.deleteDocument(oldCodeRef)
            let index = FirestoreModels.FJoinCodeIndex(
                careCircleID: circleID,
                regeneratedAt: Date()
            )
            let payload = try Firestore.Encoder().encode(index)
            batch.setData(payload, forDocument: newCodeRef)

            #if DEBUG
            print("[REGENERATE-DEBUG] batch.commit circle=\(circleID) old=\(oldCode) new=\(newCode)")
            #endif
            try await batch.commit()
            #if DEBUG
            print("[REGENERATE-DEBUG] commit succeeded for circle=\(circleID)")
            #endif
        } catch {
            #if DEBUG
            let ns = error as NSError
            print("[REGENERATE-DEBUG] commit threw: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
            #endif
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

    /// Lists every Person doc under the circle. Throws `.offline` when
    /// Firebase isn't configured — see `fetchMedications` for the
    /// rationale (the manual refresh in `SyncCoordinator.refresh` would
    /// otherwise mistake "couldn't ask" for "the circle has no
    /// people" and prune the local cache via the orphan helpers).
    func fetchPeople(circleID: String) async throws -> [FirestoreModels.FPerson] {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db.collection(Path.people(circleID)).getDocuments()
            return snap.documents.compactMap { try? $0.data(as: FirestoreModels.FPerson.self) }
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Fetches a single Person doc by full path. Used at sign-in
    /// alongside `fetchMembership` to hydrate the caller's Core Data
    /// cache before any listener fires. Returns nil when the doc
    /// doesn't exist; throws `.offline` when Firebase isn't reachable
    /// so the caller can fall back to local-only resolution.
    func fetchPerson(
        circleID: String,
        personID: String
    ) async throws -> FirestoreModels.FPerson? {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db
                .collection(Path.people(circleID))
                .document(personID)
                .getDocument()
            guard snap.exists else { return nil }
            return try decode(FirestoreModels.FPerson.self, from: snap)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    // MARK: - Medication

    /// Lists every medication doc under the circle. Used by manual
    /// pull-to-refresh in `SyncCoordinator.refresh` — the listener path
    /// keeps the cache fresh in the steady state, but a network blip or
    /// a backgrounded session can stale the listener; the manual refresh
    /// is the user's recovery handle. Throws `.offline` when Firebase
    /// isn't configured so the refresher doesn't mistake "couldn't ask"
    /// for "nothing exists" and wipe the local cache via the orphan
    /// cleanup in the mirror helpers.
    func fetchMedications(circleID: String) async throws -> [FirestoreModels.FMedication] {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db.collection(Path.medications(circleID)).getDocuments()
            return snap.documents.compactMap { try? $0.data(as: FirestoreModels.FMedication.self) }
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

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

    /// See `fetchMedications` — same contract, same reason.
    func fetchDoseSchedules(circleID: String) async throws -> [FirestoreModels.FDoseSchedule] {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db.collection(Path.doseSchedules(circleID)).getDocuments()
            return snap.documents.compactMap { try? $0.data(as: FirestoreModels.FDoseSchedule.self) }
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

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

    /// See `fetchMedications` — same contract, same reason.
    func fetchDoseLogs(circleID: String) async throws -> [FirestoreModels.FDoseLog] {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db.collection(Path.doseLogs(circleID)).getDocuments()
            return snap.documents.compactMap { try? $0.data(as: FirestoreModels.FDoseLog.self) }
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

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

    // MARK: - Alerts

    /// Same contract as `fetchPeople` etc. Throws `.offline` when the
    /// SDK isn't configured rather than returning an empty array — the
    /// pull-to-refresh path would otherwise mistake "couldn't ask" for
    /// "no alerts" and prune the local mirror.
    func fetchAlerts(circleID: String) async throws -> [FirestoreModels.FAlert] {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db.collection(Path.alerts(circleID))
                .order(by: "createdAt", descending: true)
                .limit(to: 50)
                .getDocuments()
            return snap.documents.compactMap { try? $0.data(as: FirestoreModels.FAlert.self) }
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Idempotent create. Used by `MissedDoseDetector` and
    /// `WeeklySummaryGenerator` — multiple supervisor devices detecting
    /// the same gap converge on the same `alertID`, and only the first
    /// write commits. Subsequent writes raise `.alreadyExists`, which
    /// the caller treats as success ("the alert is already there").
    /// Returns `true` when this call wrote the doc, `false` when it
    /// was already present.
    @discardableResult
    func createAlertIfAbsent(circleID: String,
                             alert: FirestoreModels.FAlert) async throws -> Bool {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            var payload = try encode(alert)
            payload["createdAt"] = FieldValue.serverTimestamp()
            payload["lastModified"] = FieldValue.serverTimestamp()
            // setData with merge: false on an existing doc errors;
            // a get-then-write prelude avoids burning the SDK's local
            // queue with a doomed write while still being race-safe
            // because the rules-layer create blocks duplicate landings.
            let ref = db.collection(Path.alerts(circleID)).document(alert.id)
            let snap = try await ref.getDocument()
            if snap.exists { return false }
            try await ref.setData(payload)
            return true
        } catch let error as NSError where
            error.domain == FirestoreErrorDomain &&
            error.code == FirestoreErrorCode.alreadyExists.rawValue {
            // A concurrent write from another device beat us by a hair.
            // Treat as success — the alert is in the system either way.
            return false
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Atomic acknowledgement. Reads the doc inside a transaction; if
    /// `acknowledgedBy` is already non-nil, returns silently (someone
    /// else got there first — the listener will reconcile). Otherwise
    /// stamps the caller's UID + name + server timestamp.
    func acknowledgeAlert(circleID: String,
                          alertID: String,
                          firebaseUID: String,
                          actorName: String?) async throws {
        guard let db else { throw FirestoreServiceError.offline }
        let ref = db.collection(Path.alerts(circleID)).document(alertID)
        Self.alertsLogger.debug("acknowledgeAlert: transaction start alert=\(alertID, privacy: .public)")
        // Firestore transactions can retry up to 5 times. Counting the
        // closure invocations gives visibility into "ack succeeded but
        // UI didn't update" — a retry that lost the race writes nothing
        // and the listener delivers the winning state.
        let attemptCounter = AttemptCounter()
        do {
            _ = try await db.runTransaction({ (txn, errorPointer) -> Any? in
                let attempt = attemptCounter.next()
                Self.alertsLogger.debug("acknowledgeAlert: txn attempt #\(attempt, privacy: .public) alert=\(alertID, privacy: .public)")
                let snap: DocumentSnapshot
                do {
                    snap = try txn.getDocument(ref)
                } catch let error as NSError {
                    errorPointer?.pointee = error
                    return nil
                }
                guard let data = snap.data() else { return nil }
                if let existing = data["acknowledgedBy"] as? String, !existing.isEmpty {
                    return nil  // someone else won the race
                }
                var update: [String: Any] = [
                    "acknowledgedBy": firebaseUID,
                    "acknowledgedAt": FieldValue.serverTimestamp(),
                    "lastModified": FieldValue.serverTimestamp()
                ]
                if let actorName, !actorName.isEmpty {
                    update["acknowledgedByName"] = actorName
                }
                txn.updateData(update, forDocument: ref)
                return nil
            })
        } catch {
            // Distinct error codes per error-collapse convention —
            // see build_log April 30 phantom join code entry.
            throw FirestoreServiceError.map(error)
        }
    }

    private static let alertsLogger = Logger(subsystem: "com.medication.dosely", category: "alerts")
    private static let roleLogger = Logger(subsystem: "com.medication.dosely", category: "role-transitions")

    /// Tiny thread-safe counter for transaction retry visibility. The
    /// runTransaction closure is invoked once per attempt and Firestore
    /// may parallelize-then-retry; a Sendable lock is enough.
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: - Medical ID

    /// Reads the per-person medical ID doc. Returns nil if it hasn't
    /// been created yet — the editor renders an empty form against
    /// nil. Throws `.offline` when the SDK isn't configured.
    func fetchMedicalID(circleID: String, personID: String) async throws -> FirestoreModels.FMedicalID? {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db.document(Path.medicalID(circleID, personID: personID)).getDocument()
            guard snap.exists else { return nil }
            return try decode(FirestoreModels.FMedicalID.self, from: snap)
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Writes the medical ID. `setData` with no merge — every save
    /// is a full replacement of the doc, which matches how the
    /// editor surfaces the form (everything is editable, everything
    /// is in the same payload).
    ///
    /// Payload is built explicitly rather than through `Firestore.Encoder`
    /// because the rules check is strict (`updatedAt == request.time`
    /// AND `id == personID` AND `personID == personID`). The previous
    /// encode-then-override pattern left a transient
    /// `updatedAt: Date(client)` in the dict for the brief window
    /// before the FieldValue sentinel overwrote it — most SDK versions
    /// handle the override correctly, but the wire shape was harder to
    /// reason about, and a single permission-denied on production
    /// burnt enough hours to justify the verbose form. Optional fields
    /// are conditionally included so a nil `notes` doesn't ship as
    /// `null` (which the listener-side decode handles, but the
    /// emergency-info display reads the field directly).
    func upsertMedicalID(circleID: String,
                         medicalID: FirestoreModels.FMedicalID) async throws {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            var payload: [String: Any] = [
                "id": medicalID.personID,        // must equal personID per rules
                "personID": medicalID.personID,  // must equal personID per rules
                "allergies": medicalID.allergies,
                "conditions": medicalID.conditions,
                "emergencyContacts": medicalID.emergencyContacts.map { contact in
                    [
                        "name": contact.name,
                        "relationship": contact.relationship,
                        "phone": contact.phone
                    ]
                },
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let dob = medicalID.dateOfBirth {
                payload["dateOfBirth"] = Timestamp(date: dob)
            }
            if let bloodType = medicalID.bloodType, !bloodType.isEmpty {
                payload["bloodType"] = bloodType
            }
            if let notes = medicalID.notes, !notes.isEmpty {
                payload["notes"] = notes
            }
            try await db
                .document(Path.medicalID(circleID, personID: medicalID.personID))
                .setData(payload)
        } catch {
            // Distinct error codes per error-collapse convention —
            // see build_log April 30 phantom join code entry.
            throw FirestoreServiceError.map(error)
        }
    }

    /// Removes a person's medical ID. Called from the person-removal
    /// cascade in `PersonRepository.removePersonFromCircle` so the
    /// orphaned doc doesn't sit forever.
    func deleteMedicalID(circleID: String, personID: String) async throws {
        guard let db else { return }
        do {
            try await db.document(Path.medicalID(circleID, personID: personID)).delete()
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    // MARK: - Orphan cleanup

    /// Lists every doc in `/joinCodes`. Each entry is `(code,
    /// careCircleID)`. Used by `OrphanCircleCleanupMigration` to
    /// enumerate candidate circles a user may have founded but no
    /// longer has membership in.
    func listAllJoinCodes() async throws -> [(code: String, careCircleID: String)] {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let snap = try await db.collection(Path.joinCodes).getDocuments()
            return snap.documents.compactMap { doc in
                guard let careCircleID = doc.data()["careCircleID"] as? String else { return nil }
                return (code: doc.documentID, careCircleID: careCircleID)
            }
        } catch {
            throw FirestoreServiceError.map(error)
        }
    }

    /// Recursively tears down a careCircle the caller founded but no
    /// longer belongs to: every Person, Medication, DoseSchedule,
    /// DoseLog, MedicalProfile, Alert, and FamilyContact under it; every
    /// `/joinCodes` doc that points at it; the careCircle root doc
    /// itself.
    ///
    /// Delete order matters because the rules-layer
    /// `isOrphanFounder(circleID)` check resolves the founder via
    /// `careCircle.primarySupervisorPersonID` → `/people/{primaryID}`
    /// → that Person doc's `firebaseUID`. The careCircle root and the
    /// founder's Person doc must both exist at the moment any rule
    /// uses them. The strategy:
    ///
    /// 1. Delete every non-Person subcollection doc (medications,
    ///    doseSchedules, doseLogs, medicalProfiles, alerts,
    ///    familyContacts). Founder Person doc is untouched, so
    ///    `isOrphanFounder` keeps passing.
    /// 2. Delete every Person doc EXCEPT the founder's. The founder's
    ///    Person doc is the rules helper's anchor — pulling it before
    ///    the careCircle root would orphan the careCircle delete.
    /// 3. Delete `/joinCodes/{code}` lookups for this circle. The rule
    ///    on those reads the careCircle (still present) and the founder
    ///    Person doc (still present).
    /// 4. Single Firestore batch: founder's Person doc + careCircle
    ///    root. Both writes' rules evaluate against the pre-batch state
    ///    where both still exist, so `isOrphanFounder` passes for both.
    ///
    /// Throws `.permissionDenied` when the caller isn't actually the
    /// founder of `circleID`; the migration treats that as "skip,
    /// not our orphan."
    func deleteOrphanedCareCircle(circleID: String) async throws {
        guard let db else { throw FirestoreServiceError.offline }
        do {
            let circleSnap = try await db.document(Path.careCircle(circleID)).getDocument()
            guard let founderPersonID = circleSnap.data()?["primarySupervisorPersonID"] as? String,
                  !founderPersonID.isEmpty else {
                // No primarySupervisorPersonID means the rules' founder
                // anchor doesn't exist either, so we couldn't have
                // deleted any of this anyway. Bail.
                return
            }

            let subcollections = [
                Path.medications(circleID),
                Path.doseSchedules(circleID),
                Path.doseLogs(circleID),
                Path.medicalProfiles(circleID),
                Path.alerts(circleID),
                Path.familyContacts(circleID)
            ]
            for path in subcollections {
                let snap = try await db.collection(path).getDocuments()
                for doc in snap.documents {
                    try await doc.reference.delete()
                }
            }

            let peopleSnap = try await db.collection(Path.people(circleID)).getDocuments()
            for doc in peopleSnap.documents where doc.documentID != founderPersonID {
                try await doc.reference.delete()
            }

            let codeSnap = try await db.collection(Path.joinCodes)
                .whereField("careCircleID", isEqualTo: circleID)
                .getDocuments()
            for doc in codeSnap.documents {
                try await doc.reference.delete()
            }

            let batch = db.batch()
            batch.deleteDocument(
                db.collection(Path.people(circleID)).document(founderPersonID)
            )
            batch.deleteDocument(db.document(Path.careCircle(circleID)))
            try await batch.commit()
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
