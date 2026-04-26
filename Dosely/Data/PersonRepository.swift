import CoreData
import Foundation

enum PersonRepositoryError: Error, Equatable {
    case notFound
    case permissionDenied
    case alreadyExists
    case invalidPin
}

final class PersonRepository {
    static let pinFailureThreshold: Int16 = 3

    private let stack: CoreDataStack

    init(stack: CoreDataStack = .shared) {
        self.stack = stack
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

        return await context.perform { [context] in
            let person = Person(context: context)
            person.id = UUID()
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
        await context.perform { [context] in
            let person = Person(context: context)
            person.id = UUID()
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
        await context.perform { [context] in
            let person = Person(context: context)
            person.id = UUID()
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
        await context.perform { [context] in
            guard let person = Self.find(id: id, in: context) else { return }
            if let name { person.name = name }
            if let photoData { person.photoData = photoData }
            if let language { person.languagePreference = language }
            try? context.save()
        }
    }

    // MARK: - PIN

    /// Verifies a PIN, increments `failedPinAttempts` on failure, resets on
    /// success. Returns `(verified: Bool, lockoutTriggered: Bool)`.
    /// Lockout fires when failures cross `pinFailureThreshold` — the
    /// caller (Prompt 15) wires this to a supervisor notification.
    @discardableResult
    func verifyPin(personID: UUID, pinPlaintext: String) async -> (verified: Bool, lockoutTriggered: Bool) {
        await context.perform { [context] in
            guard let person = Self.find(id: personID, in: context),
                  let saltStr = person.pinSalt, let saltData = Data(base64Encoded: saltStr),
                  let hashStr = person.pinHash, let hashData = Data(base64Encoded: hashStr)
            else { return (false, false) }

            if PinHasher.verify(pin: pinPlaintext, hash: hashData, salt: saltData) {
                person.failedPinAttempts = 0
                try? context.save()
                return (true, false)
            }

            person.failedPinAttempts &+= 1
            let triggered = person.failedPinAttempts >= Self.pinFailureThreshold
            try? context.save()
            return (false, triggered)
        }
    }

    /// Sets a new PIN for a device client. Permission: only a supervisor
    /// in the same care circle may call this; the call site must pass the
    /// acting supervisor's id and the repository validates.
    func resetPin(
        personID: UUID,
        newPinPlaintext: String,
        actingSupervisorID: UUID
    ) async throws {
        let salt = PinHasher.generateSalt()
        guard let hash = PinHasher.hash(pin: newPinPlaintext, salt: salt) else {
            throw PersonRepositoryError.invalidPin
        }

        try await context.perform { [context] in
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
