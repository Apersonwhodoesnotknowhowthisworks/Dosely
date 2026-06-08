import CoreData
import Foundation

/// Keeps `PeopleManagementView`'s parent render condition reactive to the
/// acting Person's `careCircle` **relationship** landing in Core Data.
///
/// The June 8 fix made the Care circle *card* observe Core Data, but in the
/// same pass it moved the circle-id derivation up to the parent as
/// `if isLoaded, let circleID = authService.currentPerson?.careCircle?.id`.
/// That is a one-shot snapshot read of an `NSManagedObject` relationship.
/// SwiftUI re-evaluates the body when `AuthService` republishes `currentPerson`
/// (a *reassignment*), NOT when the existing Person's `careCircle` relationship
/// is filled in place — the `createCareCircle` write, or a SyncCoordinator
/// listener mirror, both mutate the live object without reassigning it. So on a
/// freshly-created account the guard could read nil, the whole section was
/// omitted, and nothing ever re-evaluated it. Same class of bug as the card it
/// gates, one layer up; same cure as `CircleSettingsViewModel` and the May 28
/// `SupervisorDashboardViewModel.actorIsPrimary`.
///
/// The acting Person is supplied through `bind(person:)` *after* init rather
/// than through the initializer — mirroring how `SupervisorDashboardView` feeds
/// its view model ids. `authService` is an `@EnvironmentObject` and isn't
/// available when the view constructs its `@StateObject`, so the view binds
/// once the environment is live (from its `.task`).
@MainActor
final class PeopleManagementViewModel: ObservableObject {
    /// The acting person's care-circle id, kept current with in-place
    /// relationship mutations. `nil` while the person has no circle yet
    /// (mid-create, before the relationship resolves).
    @Published private(set) var careCircleID: UUID?

    private let stack: CoreDataStack
    private var person: Person?
    private var observer: NSObjectProtocol?

    init(stack: CoreDataStack = .shared, person: Person? = nil) {
        self.stack = stack
        self.person = person
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: stack.viewContext,
            queue: .main
        ) { [weak self] _ in
            // Fires on direct viewContext writes AND on background-context
            // merges into it (the view context has
            // `automaticallyMergesChangesFromParent` on), so both the
            // synchronous `createCareCircle` write and the SyncCoordinator
            // listener mirror reach us here.
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Binds the acting Person whose `careCircle` relationship this model
    /// tracks. Called from the view once `authService.currentPerson` is
    /// available, and again whenever it is reassigned (a new id).
    func bind(person: Person?) {
        self.person = person
        refresh()
    }

    /// Re-read the circle id from the live relationship and republish only on a
    /// real change. The no-op guard keeps an unrelated viewContext change (some
    /// other row) from thrashing the view — SwiftUI is invalidated only when
    /// the id actually moves.
    private func refresh() {
        let newValue = person?.careCircle?.id
        if newValue != careCircleID { careCircleID = newValue }
    }
}
