import CoreData
import Foundation

/// Domain errors the editor maps to user-facing copy. Mirrors the
/// `FirestoreServiceError` shape one-to-one — repositories surface
/// these distinct cases rather than collapsing everything to
/// `.offline`, per the project-wide error-collapse convention
/// (see build_log April 30 "Phantom join code bug" and May 13
/// "Medical ID save permission denied"). A connection-error message
/// on a rules rejection sends supervisors chasing the wrong cause.
enum MedicalIDRepositoryError: Error, Equatable {
    case permissionDenied
    case offline
    case notFound
    case unknown(String)
}

/// Reads + writes the per-person `MedicalID`. Reads stay synchronous
/// from Core Data so the editor renders instantly with the last-known
/// state; writes hit Firestore first and the Core Data row is only
/// updated after the remote confirms. This mirrors the
/// `regenerateJoinCode` pattern — never let the local cache hold a
/// value that didn't land on the server, because emergency responders
/// will trust whatever the screen shows.
final class MedicalIDRepository {
    private let stack: CoreDataStack
    private let firestore: FirestoreService

    init(stack: CoreDataStack = .shared,
         firestore: FirestoreService = .shared) {
        self.stack = stack
        self.firestore = firestore
    }

    private var context: NSManagedObjectContext { stack.viewContext }

    // MARK: - Read (Core Data synchronous)

    /// Returns the locally-cached medical ID for the person, or nil
    /// if none exists yet. The remote fetch lives in `loadRemote`
    /// below — the editor calls that on appear to pull the latest.
    func fetchLocal(personID: UUID) async -> MedicalID? {
        await context.perform { [context] in
            let request = NSFetchRequest<MedicalID>(entityName: "MedicalID")
            request.predicate = NSPredicate(format: "personID == %@", personID as CVarArg)
            request.fetchLimit = 1
            return (try? context.fetch(request))?.first
        }
    }

    /// Hits Firestore for the current canonical state and mirrors it
    /// into Core Data on success. Returns the mirrored row, or nil
    /// if no doc exists yet (a brand-new person). Throws `.offline`
    /// when the SDK isn't reachable so the caller can fall back to
    /// the local cache.
    @discardableResult
    func loadRemote(personID: UUID, circleID: UUID) async throws -> MedicalID? {
        let remote = try await firestore.fetchMedicalID(
            circleID: circleID.uuidString,
            personID: personID.uuidString
        )
        guard let remote else { return nil }
        return await context.perform { [context] in
            let row = remote.upsert(in: context)
            try? context.save()
            return row
        }
    }

    // MARK: - Write (Firestore-first)

    /// Saves the supplied medical ID. Firestore commit happens first;
    /// only on success do we update the Core Data mirror. A failure
    /// leaves the local row untouched so the editor doesn't surface
    /// a value the rest of the family can't see.
    func save(personID: UUID,
              circleID: UUID,
              dateOfBirth: Date?,
              bloodType: String?,
              allergies: [String],
              conditions: [String],
              emergencyContacts: [FirestoreModels.FEmergencyContact],
              notes: String?) async throws {
        let payload = FirestoreModels.FMedicalID(
            id: personID.uuidString,
            personID: personID.uuidString,
            dateOfBirth: dateOfBirth,
            bloodType: trimmed(bloodType),
            allergies: allergies.compactMap(trimmedString),
            conditions: conditions.compactMap(trimmedString),
            emergencyContacts: emergencyContacts.compactMap(trimmedContact),
            notes: trimmed(notes),
            updatedAt: Date()
        )
        do {
            try await firestore.upsertMedicalID(
                circleID: circleID.uuidString,
                medicalID: payload
            )
        } catch FirestoreServiceError.permissionDenied {
            // Distinct error codes per error-collapse convention —
            // see build_log April 30 phantom join code entry.
            throw MedicalIDRepositoryError.permissionDenied
        } catch FirestoreServiceError.offline {
            throw MedicalIDRepositoryError.offline
        } catch let FirestoreServiceError.unknown(detail) {
            throw MedicalIDRepositoryError.unknown(detail)
        } catch {
            throw MedicalIDRepositoryError.unknown("\(error)")
        }
        await context.perform { [context] in
            payload.upsert(in: context)
            try? context.save()
        }
    }

    /// Strips empty/whitespace strings off lists and contacts before
    /// they hit Firestore — supervisors will inevitably leave trailing
    /// blank rows from the "+ Add" pattern, and we don't want those
    /// to render as ghost entries on another device.
    private func trimmedString(_ value: String) -> String? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func trimmedContact(_ contact: FirestoreModels.FEmergencyContact)
        -> FirestoreModels.FEmergencyContact?
    {
        let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let relationship = contact.relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = contact.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty && relationship.isEmpty && phone.isEmpty { return nil }
        return FirestoreModels.FEmergencyContact(
            name: name, relationship: relationship, phone: phone
        )
    }
}
