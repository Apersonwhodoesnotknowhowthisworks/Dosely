import CoreData
import Foundation

enum PersonRepositoryError: Error, Equatable {
    case notFound
    case permissionDenied
    case alreadyExists
    case invalidPin
    case lastSupervisor
    case invalidRoleTransition
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

    func fetchSupervisor(firebaseUID: String) async -> Person? {
        await context.perform { [context] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(format: "firebaseUID == %@ AND role == %@",
                                            firebaseUID, "supervisor")
            request.fetchLimit = 1
            return (try? context.fetch(request))?.first
        }
    }

    // MARK: - Writes

    @discardableResult
    func createDeviceClient(
        name: String,
        photoData: Data?,
        pinPlaintext: String,
        language: String,
        in careCircle: CareCircle
    ) async -> Person {
        let salt = PinHasher.generateSalt()
        let hash = PinHasher.hash(pin: pinPlaintext, salt: salt) ?? Data()
        let personID = UUID()
        let circleID = careCircle.id ?? UUID()

        let fperson = FirestoreModels.FPerson(
            id: personID.uuidString,
            careCircleID: circleID.uuidString,
            name: name,
            role: "device_client",
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
            let person = Person(context: context)
            person.id = personID
            person.name = name
            person.photoData = photoData
            person.role = "device_client"
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
        in careCircle: CareCircle
    ) async -> Person {
        let personID = UUID()
        let circleID = careCircle.id ?? UUID()

        let fperson = FirestoreModels.FPerson(
            id: personID.uuidString,
            careCircleID: circleID.uuidString,
            name: name,
            role: "managed_client",
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
            let person = Person(context: context)
            person.id = personID
            person.name = name
            person.photoData = photoData
            person.role = "managed_client"
            person.languagePreference = language
            person.failedPinAttempts = 0
            person.careCircle = careCircle
            try? context.save()
            return person
        }
    }

    @discardableResult
    func createSupervisor(
        name: String,
        firebaseUID: String,
        language: String,
        in careCircle: CareCircle
    ) async -> Person {
        let personID = UUID()
        let circleID = careCircle.id ?? UUID()

        let fperson = FirestoreModels.FPerson(
            id: personID.uuidString,
            careCircleID: circleID.uuidString,
            name: name,
            role: "supervisor",
            languagePreference: language,
            firebaseUID: firebaseUID,
            photoData: nil,
            pinHash: nil,
            pinSalt: nil,
            failedPinAttempts: 0,
            lastModified: nil
        )
        try? await firestore.upsertPerson(fperson)

        return await context.perform { [context] in
            let person = Person(context: context)
            person.id = personID
            person.name = name
            person.role = "supervisor"
            person.languagePreference = language
            person.firebaseUID = firebaseUID
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
        let snapshot = await context.perform { [context] -> FirestoreModels.FPerson? in
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
            guard actor.role == "supervisor",
                  actor.careCircle?.id == target.careCircle?.id else {
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
        let salt: Data?
        let hash: Data?
        if newRole == "device_client" {
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
            guard actor.role == "supervisor",
                  actor.careCircle?.id == target.careCircle?.id else {
                throw PersonRepositoryError.permissionDenied
            }
            let allowed: Set<String> = ["device_client", "managed_client"]
            guard allowed.contains(target.role ?? ""), allowed.contains(newRole) else {
                throw PersonRepositoryError.invalidRoleTransition
            }

            target.role = newRole
            target.failedPinAttempts = 0
            if newRole == "device_client" {
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
        let context = self.context
        struct CascadeIDs {
            let personID: UUID
            let circleID: UUID
            let medicationIDs: [UUID]
        }

        let cascade: CascadeIDs = try await context.perform {
            guard let target = Self.find(id: personID, in: context) else {
                throw PersonRepositoryError.notFound
            }
            guard let actor = Self.find(id: actingSupervisorID, in: context) else {
                throw PersonRepositoryError.notFound
            }
            guard actor.role == "supervisor",
                  actor.careCircle?.id == target.careCircle?.id else {
                throw PersonRepositoryError.permissionDenied
            }

            if target.role == "supervisor" {
                let circlePeople = (target.careCircle?.people as? Set<Person>) ?? []
                let remainingSupervisors = circlePeople.filter {
                    $0.role == "supervisor" && $0.id != target.id
                }
                if remainingSupervisors.isEmpty {
                    throw PersonRepositoryError.lastSupervisor
                }
            }

            guard let targetID = target.id, let circleID = target.careCircle?.id else {
                throw PersonRepositoryError.notFound
            }

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
            return CascadeIDs(personID: targetID, circleID: circleID, medicationIDs: medIDs)
        }

        // Firestore cascade: delete the person doc and every medication
        // (which itself cascades schedules + logs in FirestoreService).
        try? await firestore.deletePerson(
            circleID: cascade.circleID.uuidString,
            personID: cascade.personID.uuidString
        )
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
