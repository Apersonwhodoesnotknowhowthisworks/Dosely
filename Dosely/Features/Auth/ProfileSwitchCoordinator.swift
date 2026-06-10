import CoreData
import Foundation
import OSLog

/// Why this flow gets its own error enum: every case maps one-to-one to
/// distinct user-facing copy (`profileswitch.error.*`) per the error-collapse
/// convention — see CLAUDE.md "Error-collapse convention". There is no
/// `.offline` analog here on purpose: a profile switch is a purely local
/// operation (no Firestore write), so a network case would be a lie.
enum ProfileSwitchError: Error, Equatable {
    case notPrimarySupervisor
    case selfTargetNotAllowed
    case targetNotInSameCircle
    case targetIneligible  // not a managed_client or device_client
    case targetNotFound
}

/// The act-as overlay: lets the primary supervisor view the app through a
/// family member's lens without changing the Firebase identity.
///
/// Two layers of identity (design decision D1): `currentPerson` on
/// `AuthService` stays the Firebase-resolved supervisor at all times;
/// `actingPersonID` here is a local-only pointer to the person whose VIEW the
/// supervisor has switched into. `actorPerson` resolves the acting target when
/// set, else falls back to `currentPerson` — it is the single read every
/// routing / gating / whose-data decision uses. Write attribution
/// (`loggedByPersonID`) deliberately keeps reading `currentPerson` so the
/// family record stays honest about who actually tapped.
///
/// Lives in its own class rather than directly on `AuthService` because
/// `AuthService.init` touches live `Auth.auth()` and kicks
/// `resolveCurrentPerson` against production Firestore in the test host (the
/// June 4 test-host note) — this class takes an injected stack + defaults so
/// `AuthServiceProfileSwitchTests` can drive every branch hermetically, the
/// same seam pattern as the view models.
@MainActor
final class ProfileSwitchCoordinator: ObservableObject {
    /// Persisted across relaunch (D6): entering act-as is a deliberate
    /// choice, and silently reverting on a cold start would surprise the
    /// supervisor more than resuming where they left off. They can always
    /// tap "Switch back" in the banner.
    @Published private(set) var actingPersonID: UUID?

    /// Resolves the signed-in Person (the Firebase identity). Wired by
    /// `AuthService` after init; a closure rather than a stored reference so
    /// the coordinator never retains the service and tests can stub it.
    var currentPersonProvider: () -> Person? = { nil }

    static let defaultsKey = "acting_person_id"

    private let stack: CoreDataStack
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private static let logger = Logger(subsystem: "com.medication.dosely", category: "profile-switch")

    init(stack: CoreDataStack = .shared, defaults: UserDefaults = .standard) {
        self.stack = stack
        self.defaults = defaults

        // Hydrate from the persisted value. An orphaned UUID (the stored
        // person no longer exists locally — edge case 9e) clears gracefully
        // instead of routing the supervisor into a void.
        if let stored = defaults.string(forKey: Self.defaultsKey), !stored.isEmpty {
            if let id = UUID(uuidString: stored),
               PersonRepository.find(id: id, in: stack.viewContext) != nil {
                actingPersonID = id
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
                Self.logger.error("hydrate: stored acting_person_id \(stored, privacy: .public) doesn't resolve to a local Person — cleared")
            }
        }

        // Edge cases 9a/9b: the acting target can be deleted by another
        // supervisor, or this supervisor can be demoted, while act-as is
        // live. Both land as SyncCoordinator background-context merges into
        // the viewContext, so the established ObjectsDidChange observer
        // pattern (May 28 / June 7 / June 8) is the revalidation trigger.
        let viewContext = stack.viewContext
        observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: viewContext,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.revalidate()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The single identity read for routing, gating, and whose-data
    /// decisions. Side-effect free: when the acting target fails to resolve
    /// this falls back to `currentPerson` and lets `revalidate()` (driven by
    /// the ObjectsDidChange observer) clear the stale pointer — a getter that
    /// mutates published state mid-body-evaluation would trip SwiftUI's
    /// "publishing changes from within view updates".
    var actorPerson: Person? {
        if let id = actingPersonID,
           let acting = PersonRepository.find(id: id, in: stack.viewContext),
           acting.managedObjectContext != nil, !acting.isDeleted {
            return acting
        }
        return currentPersonProvider()
    }

    func actAs(personID: UUID) throws {
        let actor = currentPersonProvider()
        let target = PersonRepository.find(id: personID, in: stack.viewContext)
        Self.logger.log("actAs requested: actor=\(actor?.id?.uuidString ?? "nil", privacy: .public) target=\(personID.uuidString, privacy: .public) targetRole=\(target?.role ?? "nil", privacy: .public)")
        if let error = Self.validate(actor: actor, target: target) {
            Self.logger.error("actAs rejected: \(String(describing: error), privacy: .public)")
            throw error
        }
        setActing(personID)
        Self.logger.log("actAs succeeded: acting as \(personID.uuidString, privacy: .public)")
    }

    func switchBack() {
        guard let previous = actingPersonID else { return }
        setActing(nil)
        Self.logger.log("switchBack: switched back from \(previous.uuidString, privacy: .public)")
    }

    /// Edge case 9d: ending the Firebase session must not leak act-as into
    /// the next sign-in. The lock-only `signOut()` deliberately does NOT call
    /// this — a Face ID unlock resumes the same session, and D6 says a live
    /// session's act-as choice persists.
    func clearOnSignOut() {
        guard actingPersonID != nil else { return }
        setActing(nil)
        Self.logger.log("clearOnSignOut: acting state cleared with the session")
    }

    /// Re-checks the act-as preconditions against live Core Data state.
    /// Called from the ObjectsDidChange observer and after
    /// `resolveCurrentPerson` lands a (possibly different) currentPerson.
    func revalidate() {
        guard let actingID = actingPersonID else { return }

        // 9a — the acting person was deleted (e.g. removed by another
        // supervisor; the SyncCoordinator orphan sweep hard-deletes the row).
        guard let target = PersonRepository.find(id: actingID, in: stack.viewContext),
              target.managedObjectContext != nil, !target.isDeleted else {
            setActing(nil)
            Self.logger.error("revalidate: acting person \(actingID.uuidString, privacy: .public) no longer exists — switched back")
            return
        }

        // The target must STAY eligible (D3): if its role ever became a
        // supervisor flavour mid-switch, AuthGate would route the lens to
        // the dashboard under an "Acting as" banner — an incoherent hybrid.
        // Unreachable through today's flows (role flips are device↔managed
        // only), but the revalidation loop should maintain every invariant
        // its own entry validation enforces.
        guard target.role == Roles.managedClient || target.role == Roles.deviceClient else {
            setActing(nil)
            Self.logger.error("revalidate: acting person \(actingID.uuidString, privacy: .public) is no longer a client role — switched back")
            return
        }

        // 9b — the supervisor was demoted mid-act-as: the lens must drop so
        // the audit-trust property holds. Deliberately the SAME predicate as
        // the entry validation (isPrimary), not the looser isAnySupervisor:
        // the common demotion here is primary→secondary (a promotion handoff
        // from another device), and a secondary holding a lens they could
        // never start would sit on dose buttons that silently no-op
        // (logDose rejects secondaries). Only checked when currentPerson has
        // resolved; it is briefly nil during cold-start resolution and that
        // must not clear a valid state.
        guard let current = currentPersonProvider(),
              current.managedObjectContext != nil, !current.isDeleted else { return }
        if !Self.isPrimary(current) {
            setActing(nil)
            Self.logger.error("revalidate: actor \(current.id?.uuidString ?? "?", privacy: .public) is no longer the primary — switched back")
            return
        }
        // A fresh sign-in (or circle change) whose target crosses circles is
        // the same trust violation as 9b — clear rather than show a stranger.
        if target.careCircle?.id == nil || target.careCircle?.id != current.careCircle?.id {
            setActing(nil)
            Self.logger.error("revalidate: acting person left the actor's circle — switched back")
        }
    }

    // MARK: - Eligibility (D2 / D3)

    /// Pure precondition check so `AuthServiceProfileSwitchTests` can pin
    /// every branch without Firebase. Order matters for error distinctness:
    /// self-targeting is reported as such, not as "target is a supervisor".
    static func validate(actor: Person?, target: Person?) -> ProfileSwitchError? {
        guard let actor, isPrimary(actor) else { return .notPrimarySupervisor }
        guard let target, let targetID = target.id else { return .targetNotFound }
        if targetID == actor.id { return .selfTargetNotAllowed }
        guard let actorCircleID = actor.careCircle?.id,
              let targetCircleID = target.careCircle?.id,
              actorCircleID == targetCircleID else { return .targetNotInSameCircle }
        guard target.role == Roles.managedClient || target.role == Roles.deviceClient else {
            return .targetIneligible
        }
        return nil
    }

    /// Same primary check as the view computeds (`PersonDetailView`,
    /// `PeopleManagementView`): `primarySupervisorPersonID` is the source of
    /// truth, with the legacy-role fallback for pre-migration circles.
    static func isPrimary(_ person: Person) -> Bool {
        guard let id = person.id, let circle = person.careCircle else { return false }
        if let primaryID = circle.primarySupervisorPersonID {
            return primaryID == id
        }
        return Roles.isPrimarySupervisor(person.role)
    }

    // MARK: - Persistence

    /// `@AppStorage`-equivalent persistence under the `acting_person_id`
    /// key, written through an injected `UserDefaults` instead of the
    /// property wrapper: `@AppStorage` inside an `ObservableObject` neither
    /// publishes nor takes a per-instance store, and the `@Published` +
    /// explicit write-back shape is what keeps both reactivity and the
    /// relaunch round-trip (D6) testable.
    private func setActing(_ id: UUID?) {
        if actingPersonID != id { actingPersonID = id }
        if let id {
            defaults.set(id.uuidString, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}
