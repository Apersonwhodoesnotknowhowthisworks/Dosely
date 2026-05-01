import CoreData
import Foundation

enum PersonRepositoryError: Error, Equatable {
    case notFound
    case permissionDenied
    case alreadyExists
    case invalidPin
    case lastSupervisor
    case invalidRoleTransition
    /// `promoteToPrimary` was called with a target who isn't a secondary
    /// supervisor in the same circle (or doesn't exist).
    case invalidPromotionTarget
    /// `promoteToPrimary` was called by someone who isn't the current
    /// primary supervisor of the circle.
    case notCurrentPrimary
}

/// Person reads stay synchronous from Core Data. Writes hit Firestore
/// first; we mirror to Core Data on completion. PIN verification is
/// purely local — the hash and salt are already in Core Data — but
/// `failedPinAttempts` updates do propagate so a supervisor on another
/// device sees the lockout state.
final class PersonRepository {
    static let pinFailureThreshold: Int16 = 3

    private let stack: CoreDataStack
    private let firestore: FirestoreService

    init(stack: CoreDataStack = .shared, firestore: FirestoreService = .shared) {
        self.stack = stack
        self.firestore = firestore
    }

    private var context: NSManagedObjectContext { stack.viewContext }

    // MARK: - Reads

    func fetchAllPeople(in careCircleID: UUID) async -> [Person] {
        await context.perform { [context] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(format: "careCircle.id == %@", careCircleID as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            return (try? context.fetch(request)) ?? []
        }
    }

    func fetchPerson(id: UUID) async -> Person? {
        await context.perform { [context] in
            Self.find(id: id, in: context)
        }
    }

    /// Returns the local `Person` row for a Firebase UID whose role is
    /// any supervisor flavour: `primary_supervisor`, `secondary_supervisor`,
    /// or the legacy `supervisor`. Used by `AuthService.resolveCurrentPerson`,
    /// `CareCircleMigration`, and the upload migration to identify the
    /// caller's `Person`.
    func fetchSupervisor(firebaseUID: String) async -> Person? {
        await context.perform { [context] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(
                format: "firebaseUID == %@ AND role IN %@",
                firebaseUID,
                [Roles.primarySupervisor, Roles.secondarySupervisor, Roles.legacySupervisor]
            )
            request.fetchLimit = 1
            return (try? context.fetch(request))?.first
        }
    }

    // MARK: - Primary / write authority

    /// True iff the Person is the current primary supervisor of their
    /// circle. Reads `CareCircle.primarySupervisorPersonID` as the
    /// source of truth. Pre-migration circles (no primary stamped) fall
    /// back to "is this person the legacy supervisor?".
    func isPrimary(personID: UUID) async -> Bool {
        await context.perform { [context] in
            guard let person = Self.find(id: personID, in: context),
                  let circle = person.careCircle else { return false }
            if let primaryID = circle.primarySupervisorPersonID {
                return primaryID == personID
            }
            // Pre-migration: any supervisor flavour acts as primary.
            // Once `PrimaryRoleMigration` lands, this branch is unreachable.
            return Roles.isPrimarySupervisor(person.role)
        }
    }

    /// True iff the Person can perform supervisor-only writes
    /// (saveMedication, addPerson, removePersonFromCircle,
    /// regenerateJoinCode, etc.) in their circle. Secondary supervisors,
    /// device clients, and managed clients cannot.
    func canWrite(actorPersonID: UUID) async -> Bool {
        await isPrimary(personID: actorPersonID)
    }

    /// Atomically swaps the primary supervisor of a circle: the current
    /// primary is demoted to `secondary_supervisor`, `targetPersonID` is
    /// promoted to `primary_supervisor`, and `CareCircle.primarySupervisorPersonID`
    /// is updated — all in a single Firestore batch via
    /// `applyPrimaryAssignment`. The Firestore rules' `isPromotionBatch`
    /// helper recognizes this exact write shape.
    ///
    /// Throws:
    /// - `notCurrentPrimary` if the caller isn't the current primary
    /// - `invalidPromotionTarget` if the target isn't a secondary
    ///   supervisor in the same circle
    /// - any underlying `FirestoreServiceError` on rule rejection or
    ///   network failure (the local mirror is skipped)
    func promoteToPrimary(
        targetPersonID: UUID,
        actorPersonID: UUID
    ) async throws {
        struct Plan {
            let circleID: UUID
            let oldPrimaryPersonID: UUID
            let oldPrimaryFirebaseUID: String?
            let newPrimaryPersonID: UUID
            let newPrimaryFirebaseUID: String?
        }

        let plan: Plan = try await context.perform { [context] in
            guard let actor = Self.find(id: actorPersonID, in: context),
                  let circle = actor.careCircle,
                  let circleID = circle.id else {
                throw PersonRepositoryError.notFound
            }
            guard let primaryID = circle.primarySupervisorPersonID,
                  primaryID == actorPersonID,
                  Roles.isPrimarySupervisor(actor.role) else {
                throw PersonRepositoryError.notCurrentPrimary
            }
            guard let target = Self.find(id: targetPersonID, in: context),
                  target.careCircle?.id == circleID,
                  Roles.isAnySupervisor(target.role) else {
                throw PersonRepositoryError.invalidPromotionTarget
            }
            return Plan(
                circleID: circleID,
                oldPrimaryPersonID: actorPersonID,
                oldPrimaryFirebaseUID: actor.firebaseUID,
                newPrimaryPersonID: targetPersonID,
                newPrimaryFirebaseUID: target.firebaseUID
            )
        }

        try await firestore.applyPrimaryAssignment(
            circleID: plan.circleID.uuidString,
            newPrimaryPersonID: plan.newPrimaryPersonID.uuidString,
            supervisors: [
                (plan.oldPrimaryPersonID.uuidString, plan.oldPrimaryFirebaseUID),
                (plan.newPrimaryPersonID.uuidString, plan.newPrimaryFirebaseUID)
            ]
        )

        await context.perform { [context] in
            guard let oldPrimary = Self.find(id: plan.oldPrimaryPersonID, in: context),
                  let newPrimary = Self.find(id: plan.newPrimaryPersonID, in: context),
                  let circle = oldPrimary.careCircle else { return }
            oldPrimary.role = Roles.secondarySupervisor
            newPrimary.role = Roles.primarySupervisor
            circle.primarySupervisorPersonID = plan.newPrimaryPersonID
            try? context.save()
        }
    }

    /// Throws `permissionDenied` if the actor isn't the primary
    /// supervisor of their circle. Used as the early gate inside any
    /// supervisor-only write (saveMedication, etc.).
    private func ensureCanWrite(actorPersonID: UUID) async throws {
        if await canWrite(actorPersonID: actorPersonID) { return }
        throw PersonRepositoryError.permissionDenied
    }

    // MARK: - Writes

    @discardableResult
    func createDeviceClient(
        name: String,
        photoData: Data?,
        pinPlaintext: String,
        language: String,
        in careCircle: CareCircle,
        actorPersonID: UUID,
        // Defaulted so production callers don't have to pass it. Tests
        // override so they can pre-seed a row at the same id and prove
        // the create path upserts instead of duplicating.
        personID: UUID = UUID()
    ) async throws -> Person {
        try await ensureCanWrite(actorPersonID: actorPersonID)

        let salt = PinHasher.generateSalt()
        let hash = PinHasher.hash(pin: pinPlaintext, salt: salt) ?? Data()
        let circleID = careCircle.id ?? UUID()

        let fperson = FirestoreModels.FPerson(
            id: personID.uuidString,
            careCircleID: circleID.uuidString,
            name: name,
            role: Roles.deviceClient,
            languagePreference: language,
            firebaseUID: nil,
            photoData: photoData,
            pinHash: hash.base64EncodedString(),
            pinSalt: salt.base64EncodedString(),
            failedPinAttempts: 0,
            lastModified: nil
        )
        try? await firestore.upsertPerson(fperson)

        return await context.perform { [context] in
            // Upsert by id — the Firestore write above triggers the
            // /people listener on this device, and `mirrorPeople` may
            // have already inserted a Person row at this id by the
            // time we get here. Always-inserting a fresh row produced
            // two rows with the same UUID (no uniqueness constraint
            // on the entity), which the People list rendered twice
            // and the orphan-pruning sweep then deleted together.
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(format: "id == %@", personID as CVarArg)
            request.fetchLimit = 1
            let person = (try? context.fetch(request))?.first ?? Person(context: context)
            person.id = personID
            person.name = name
            person.photoData = photoData
            person.role = Roles.deviceClient
            person.languagePreference = language
            person.pinSalt = salt.base64EncodedString()
            person.pinHash = hash.base64EncodedString()
            person.failedPinAttempts = 0
            person.careCircle = careCircle
            try? context.save()
            return person
        }
    }

    @discardableResult
    func createManagedClient(
        name: String,
        photoData: Data?,
        language: String,
        in careCircle: CareCircle,
        actorPersonID: UUID,
        // See `createDeviceClient` — defaulted so production is
        // unchanged; tests inject a known id.
        personID: UUID = UUID()
    ) async throws -> Person {
        try await ensureCanWrite(actorPersonID: actorPersonID)

        let circleID = careCircle.id ?? UUID()

        let fperson = FirestoreModels.FPerson(
            id: personID.uuidString,
            careCircleID: circleID.uuidString,
            name: name,
            role: Roles.managedClient,
            languagePreference: language,
            firebaseUID: nil,
            photoData: photoData,
            pinHash: nil,
            pinSalt: nil,
            failedPinAttempts: 0,
            lastModified: nil
        )
        try? await firestore.upsertPerson(fperson)

        return await context.perform { [context] in
            // Upsert by id — see `createDeviceClient` for the rationale.
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(format: "id == %@", personID as CVarArg)
            request.fetchLimit = 1
            let person = (try? context.fetch(request))?.first ?? Person(context: context)
            person.id = personID
            person.name = name
            person.photoData = photoData
            person.role = Roles.managedClient
            person.languagePreference = language
            person.failedPinAttempts = 0
            person.careCircle = careCircle
            try? context.save()
            return person
        }
    }

    func updatePerson(id: UUID,
                      name: String? = nil,
                      photoData: Data? = nil,
                      language: String? = nil) async {
        let snapshot = await context.perform { [context] () -> FirestoreModels.FPerson? in
            guard let person = Self.find(id: id, in: context),
                  let circleID = person.careCircle?.id else { return nil }
            if let name { person.name = name }
            if let photoData { person.photoData = photoData }
            if let language { person.languagePreference = language }
            try? context.save()
            return FirestoreModels.FPerson(from: person, careCircleID: circleID)
        }
        if let snapshot { try? await firestore.upsertPerson(snapshot) }
    }

    // MARK: - PIN

    @discardableResult
    func verifyPin(personID: UUID, pinPlaintext: String) async -> (verified: Bool, lockoutTriggered: Bool) {
        let result: (verified: Bool, lockoutTriggered: Bool, snapshot: FirestoreModels.FPerson?) = await context.perform { [context] in
            guard let person = Self.find(id: personID, in: context),
                  let saltStr = person.pinSalt, let saltData = Data(base64Encoded: saltStr),
                  let hashStr = person.pinHash, let hashData = Data(base64Encoded: hashStr)
            else { return (false, false, nil) }

            if PinHasher.verify(pin: pinPlaintext, hash: hashData, salt: saltData) {
                person.failedPinAttempts = 0
                try? context.save()
                let snapshot = person.careCircle?.id.map {
                    FirestoreModels.FPerson(from: person, careCircleID: $0)
                }
                return (true, false, snapshot)
            }

            person.failedPinAttempts &+= 1
            let triggered = person.failedPinAttempts >= Self.pinFailureThreshold
            try? context.save()
            let snapshot = person.careCircle?.id.map {
                FirestoreModels.FPerson(from: person, careCircleID: $0)
            }
            return (false, triggered, snapshot)
        }

        if let snapshot = result.snapshot {
            try? await firestore.upsertPerson(snapshot)
        }
        return (result.verified, result.lockoutTriggered)
    }

    func resetPin(
        personID: UUID,
        newPinPlaintext: String,
        actingSupervisorID: UUID
    ) async throws {
        try await ensureCanWrite(actorPersonID: actingSupervisorID)

        let salt = PinHasher.generateSalt()
        guard let hash = PinHasher.hash(pin: newPinPlaintext, salt: salt) else {
            throw PersonRepositoryError.invalidPin
        }

        let snapshot: FirestoreModels.FPerson = try await context.perform { [context] in
            guard let target = Self.find(id: personID, in: context) else {
                throw PersonRepositoryError.notFound
            }
            guard let actor = Self.find(id: actingSupervisorID, in: context) else {
                throw PersonRepositoryError.notFound
            }
            guard actor.careCircle?.id == target.careCircle?.id else {
                throw PersonRepositoryError.permissionDenied
            }
            target.pinSalt = salt.base64EncodedString()
            target.pinHash = hash.base64EncodedString()
            target.failedPinAttempts = 0
            try? context.save()
            guard let circleID = target.careCircle?.id else {
                throw PersonRepositoryError.notFound
            }
            return FirestoreModels.FPerson(from: target, careCircleID: circleID)
        }

        try? await firestore.upsertPerson(snapshot)
    }

    func updatePersonRole(
        personID: UUID,
        newRole: String,
        newPinPlaintext: String?,
        actingSupervisorID: UUID
    ) async throws {
        try await ensureCanWrite(actorPersonID: actingSupervisorID)

        let salt: Data?
        let hash: Data?
        if newRole == Roles.deviceClient {
            guard let pin = newPinPlaintext else { throw PersonRepositoryError.invalidPin }
            let s = PinHasher.generateSalt()
            guard let h = PinHasher.hash(pin: pin, salt: s) else {
                throw PersonRepositoryError.invalidPin
            }
            salt = s; hash = h
        } else {
            salt = nil; hash = nil
        }

        let snapshot: FirestoreModels.FPerson = try await context.perform { [context] in
            guard let target = Self.find(id: personID, in: context) else {
                throw PersonRepositoryError.notFound
            }
            guard let actor = Self.find(id: actingSupervisorID, in: context) else {
                throw PersonRepositoryError.notFound
            }
            guard actor.careCircle?.id == target.careCircle?.id else {
                throw PersonRepositoryError.permissionDenied
            }
            let allowed: Set<String> = [Roles.deviceClient, Roles.managedClient]
            guard allowed.contains(target.role ?? ""), allowed.contains(newRole) else {
                throw PersonRepositoryError.invalidRoleTransition
            }

            target.role = newRole
            target.failedPinAttempts = 0
            if newRole == Roles.deviceClient {
                target.pinSalt = salt?.base64EncodedString()
                target.pinHash = hash?.base64EncodedString()
            } else {
                target.pinSalt = nil
                target.pinHash = nil
            }
            try? context.save()
            guard let circleID = target.careCircle?.id else {
                throw PersonRepositoryError.notFound
            }
            return FirestoreModels.FPerson(from: target, careCircleID: circleID)
        }

        try? await firestore.upsertPerson(snapshot)
    }

    func removePersonFromCircle(personID: UUID, actingSupervisorID: UUID) async throws {
        try await ensureCanWrite(actorPersonID: actingSupervisorID)

        let context = self.context
        struct CascadeIDs {
            let personID: UUID
            let circleID: UUID
            let medicationIDs: [UUID]
            let wasSupervisor: Bool
            let firebaseUID: String?
        }

        let cascade: CascadeIDs = try await context.perform {
            guard let target = Self.find(id: personID, in: context) else {
                throw PersonRepositoryError.notFound
            }
            guard let actor = Self.find(id: actingSupervisorID, in: context) else {
                throw PersonRepositoryError.notFound
            }
            guard actor.careCircle?.id == target.careCircle?.id else {
                throw PersonRepositoryError.permissionDenied
            }

            if Roles.isAnySupervisor(target.role) {
                let circlePeople = (target.careCircle?.people as? Set<Person>) ?? []
                let remainingSupervisors = circlePeople.filter {
                    Roles.isAnySupervisor($0.role) && $0.id != target.id
                }
                if remainingSupervisors.isEmpty {
                    throw PersonRepositoryError.lastSupervisor
                }
            }

            guard let targetID = target.id, let circleID = target.careCircle?.id else {
                throw PersonRepositoryError.notFound
            }
            let wasSupervisor = Roles.isAnySupervisor(target.role)
            let targetUID = target.firebaseUID

            // Collect Medication ids that reference this person so the
            // remote cascade can hit Firestore subcollections too.
            var medIDs: [UUID] = []
            let medRequest = NSFetchRequest<Medication>(entityName: "Medication")
            medRequest.predicate = NSPredicate(format: "personID == %@", targetID as CVarArg)
            for med in (try? context.fetch(medRequest)) ?? [] {
                if let medID = med.id { medIDs.append(medID) }
                context.delete(med)
            }
            let logRequest = NSFetchRequest<DoseLog>(entityName: "DoseLog")
            logRequest.predicate = NSPredicate(format: "loggedByPersonID == %@", targetID as CVarArg)
            for log in (try? context.fetch(logRequest)) ?? [] {
                context.delete(log)
            }
            context.delete(target)
            try? context.save()
            return CascadeIDs(
                personID: targetID,
                circleID: circleID,
                medicationIDs: medIDs,
                wasSupervisor: wasSupervisor,
                firebaseUID: targetUID
            )
        }

        // Firestore cascade. For supervisor removal we batch
        // (person delete + supervisorCount-- + membership delete) so the
        // rules-layer last-supervisor backstop sees a consistent state.
        // For non-supervisor removal the Person doc delete is the only
        // doc to touch under /careCircles, plus a membership delete if
        // the target had a Firebase UID.
        if cascade.wasSupervisor {
            try? await firestore.removeSupervisorAtomically(
                circleID: cascade.circleID.uuidString,
                personID: cascade.personID.uuidString,
                firebaseUID: cascade.firebaseUID
            )
        } else {
            try? await firestore.deletePerson(
                circleID: cascade.circleID.uuidString,
                personID: cascade.personID.uuidString
            )
            if let uid = cascade.firebaseUID {
                try? await firestore.deleteMembership(firebaseUID: uid)
            }
        }
        for medID in cascade.medicationIDs {
            try? await firestore.deleteMedication(
                circleID: cascade.circleID.uuidString,
                medicationID: medID.uuidString
            )
        }
    }

    // MARK: - Helpers

    static func find(id: UUID, in context: NSManagedObjectContext) -> Person? {
        let request = NSFetchRequest<Person>(entityName: "Person")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}
