import Combine
import Foundation
import LocalAuthentication
import FirebaseAuth

enum AuthError: LocalizedError {
    case biometricUnavailable
    case biometricFailed
    case sessionExpired
    case passwordMismatch

    var errorDescription: String? {
        switch self {
        case .biometricUnavailable: return "Face ID isn't available on this device."
        case .biometricFailed:      return "Face ID check failed."
        case .sessionExpired:       return "Your session has expired. Please sign in with your password."
        case .passwordMismatch:     return "The passwords you entered don't match."
        }
    }
}

@MainActor
final class AuthService: ObservableObject {
    @Published var currentUser: FirebaseAuth.User?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var needsDisclaimer: Bool = false
    @Published var needsBiometricEnrollmentPrompt: Bool = false
    /// The active Dosely Person on this device. Set after Firebase auth
    /// resolves AND a CareCircle exists for the user. The supervisor
    /// dashboard (Prompt 14) and the profile picker (Prompt 15) will read
    /// this and let the device user switch between Persons in the circle.
    @Published var currentPerson: Person?

    /// True when Firebase has authenticated this user but no `Person`
    /// row exists for them yet — the gate between "successful sign-up"
    /// and "ready to use the dashboard." AuthGate routes this state to
    /// `CircleSetupView` so the user picks between creating a new
    /// circle and joining an existing one.
    @Published var needsCircleSetup: Bool = false

    /// Local lock that gates AuthGate even when Firebase has a live session.
    /// "Firebase signed-in" and "Dosely unlocked" are intentionally separate
    /// concepts, like 1Password / Wallet / banking apps. Persists across
    /// relaunches via UserDefaults; defaults to `true` on first install.
    @Published var isLocallyLocked: Bool {
        didSet {
            UserDefaults.standard.set(isLocallyLocked, forKey: Self.lockedKey)
        }
    }

    /// The act-as overlay (profile switcher). State + eligibility live on the
    /// coordinator so they stay testable without touching live `Auth.auth()`;
    /// the service exposes thin forwarders (`actingPersonID` / `actorPerson` /
    /// `actAs` / `switchBack`) so views keep a single identity surface.
    let profileSwitch: ProfileSwitchCoordinator

    private static let lockedKey = "is_locally_locked"
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var profileSwitchForwarder: AnyCancellable?

    init() {
        UserDefaults.standard.register(defaults: [Self.lockedKey: true])
        self.isLocallyLocked = UserDefaults.standard.bool(forKey: Self.lockedKey)
        self.profileSwitch = ProfileSwitchCoordinator()
        self.currentUser = Auth.auth().currentUser
        profileSwitch.currentPersonProvider = { [weak self] in self?.currentPerson }
        // The coordinator's @Published changes must republish through this
        // object — AuthGate and the views observe `authService`, not the
        // nested coordinator.
        profileSwitchForwarder = profileSwitch.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.currentUser = user
                await self?.resolveCurrentPerson()
            }
        }
        if currentUser != nil {
            Task { await resolveCurrentPerson() }
        }
    }

    deinit {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Email / password

    func signUp(email: String, password: String) async throws {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            Keychain.set(email, for: .lastEmail)
            await refreshAndStoreToken(for: result.user)
            await resolveCurrentPerson()
            unlock()  // brand-new account is unlocked by definition
            // Post-signup state machine: biometric prompt FIRST (if the
            // device can do it and the user hasn't already enabled it),
            // disclaimer SECOND. `completeBiometricEnrollmentPrompt(...)`
            // hops to the disclaimer when the alert dismisses.
            if biometricAvailable && !biometricEnabled {
                needsBiometricEnrollmentPrompt = true
            } else {
                needsDisclaimer = !UserDefaults.standard.bool(forKey: "disclaimer_accepted")
            }
        } catch {
            errorMessage = Self.friendly(error)
            throw error
        }
    }

    /// Called from AuthGate's biometric-enrollment alert. Persists the
    /// user's choice to Keychain and advances the post-signup flow to the
    /// medical disclaimer (if it hasn't already been accepted).
    func completeBiometricEnrollmentPrompt(enableBiometric: Bool) {
        setBiometric(enabled: enableBiometric)
        needsBiometricEnrollmentPrompt = false
        needsDisclaimer = !UserDefaults.standard.bool(forKey: "disclaimer_accepted")
    }

    func signIn(email: String, password: String) async throws {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            Keychain.set(email, for: .lastEmail)
            await refreshAndStoreToken(for: result.user)
            await resolveCurrentPerson()
            unlock()
        } catch {
            errorMessage = Self.friendly(error)
            throw error
        }
    }

    // MARK: - Profile switching (act-as)

    /// Non-nil while the supervisor is viewing the app through a family
    /// member's lens. Local-only; the Firebase identity never changes.
    var actingPersonID: UUID? { profileSwitch.actingPersonID }

    /// The single identity read for routing, role gating, and whose-data
    /// decisions: the acting target while act-as is live, else
    /// `currentPerson`. Write attribution (`loggedByPersonID`) keeps reading
    /// `currentPerson` directly — the audit trail records who actually
    /// tapped, not whose view they were looking through (D5).
    var actorPerson: Person? { profileSwitch.actorPerson }

    /// Switches the app's vantage point to `personID`'s view. Preconditions
    /// (primary-only actor, client-only target, same circle, no self-target)
    /// are enforced by the coordinator and surface as distinct
    /// `ProfileSwitchError` cases per the error-collapse convention.
    func actAs(personID: UUID) async throws {
        try profileSwitch.actAs(personID: personID)
    }

    func switchBack() {
        profileSwitch.switchBack()
    }

    // MARK: - Lock / sign-out

    func lock() { isLocallyLocked = true }

    func unlock() { isLocallyLocked = false }

    /// Default sign-out: locks Dosely but keeps the Firebase session and
    /// the Keychain biometric flag alive. The user can re-enter via Face ID
    /// or by re-typing their password without losing their session.
    func signOut() {
        lock()
    }

    /// Forget-me sign-out: ends the Firebase session and wipes every
    /// Keychain entry tied to this user. Forces a full email + password
    /// sign-in to come back. Used by the destructive Settings option.
    func signOutCompletely() {
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = Self.friendly(error)
        }
        Keychain.delete(.idToken)
        Keychain.delete(.lastEmail)
        Keychain.delete(.biometricEnabled)
        currentPerson = nil
        needsCircleSetup = false
        // Act-as must not survive the session it was started in (9d).
        profileSwitch.clearOnSignOut()
        SyncCoordinator.shared.stop()
        lock()
    }

    // MARK: - Person resolution

    /// Resolves the local Person for the current Firebase user.
    ///
    /// **Membership-first.** Hits Firestore's `/userMemberships/{uid}`
    /// index before consulting Core Data. The index is the source of
    /// truth for "does this Firebase user already belong to a circle?";
    /// a Core Data miss alone — which happens on a fresh install,
    /// post-sign-out, or a first sign-in on a second device — must not
    /// be treated as proof that the user is brand-new. When the index
    /// resolves, the referenced CareCircle and Person docs are mirrored
    /// into Core Data so the dashboard renders immediately and the
    /// SyncCoordinator listener can fill in the rest.
    ///
    /// Falls back to `CareCircleMigration` only when the resolver
    /// returns `.notFound` (truly new account) or `.unavailable`
    /// (offline / no Firestore configured) — preserving the legacy
    /// orphan-reassignment path and the offline-with-cache path.
    ///
    /// Also runs the upload migration for pre-Firestore local data and
    /// the primary/secondary role migration, then starts the
    /// SyncCoordinator so cross-device updates land.
    @MainActor
    func resolveCurrentPerson() async {
        let _sp = Perf.signposter.beginInterval("coldstart.resolveCurrentPerson")
        defer { Perf.signposter.endInterval("coldstart.resolveCurrentPerson", _sp) }
        guard let user = currentUser else {
            currentPerson = nil
            needsCircleSetup = false
            // Session ended out from under us — same contract as
            // signOutCompletely: act-as does not carry to the next sign-in.
            profileSwitch.clearOnSignOut()
            SyncCoordinator.shared.stop()
            return
        }
        let displayName = user.displayName?.isEmpty == false
            ? user.displayName!
            : (user.email ?? "Me")
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"

        let outcome = await RemotePersonResolver.resolve(firebaseUID: user.uid)

        let resolved: Person?
        switch outcome {
        case .found(let person):
            // Hydrated from Firestore. Flip the legacy migration flag
            // so we don't keep sweeping for orphans on every launch —
            // a user with a Firestore membership cannot also have
            // pre-Firestore orphan rows by construction.
            UserDefaults.standard.set(true, forKey: CareCircleMigration.flagKey)
            resolved = person
        case .notFound, .unavailable:
            // `.notFound`: brand-new account — the migration creates a
            // circle iff there's legacy orphan data, otherwise returns
            // nil and AuthGate routes to CircleSetupView.
            // `.unavailable`: Firestore couldn't be reached. Fall back
            // to the local Core Data path so an offline supervisor
            // with a populated cache still lands on the dashboard.
            resolved = await CareCircleMigration.runIfNeeded(
                firebaseUID: user.uid,
                displayName: displayName,
                languagePreference: lang
            )
        }
        currentPerson = resolved
        needsCircleSetup = (resolved == nil)

        // First Firestore-aware launch on a device with pre-existing
        // local data: upload it once, then let listeners take over.
        await FirestoreUploadMigration.runIfNeeded(firebaseUID: user.uid)

        // Split legacy "supervisor" rows into primary/secondary and
        // stamp `CareCircle.primarySupervisorPersonID`. Idempotent via
        // a UserDefaults flag; runs once per device. The actor's UID
        // is passed so PHASE A can self-heal a missing /userMemberships
        // index doc (a pre-Prompt-18 production state we hit) before
        // PHASE B's atomic batch.
        await PrimaryRoleMigration.runIfNeeded(actorFirebaseUID: user.uid)

        // Tear down any care circles this user founded during earlier
        // debugging cycles but no longer belongs to. Runs once per
        // device, keyed off /userMemberships' truth and an
        // isOrphanFounder rules-layer ownership proof. No-op for
        // anyone whose data is already clean.
        await OrphanCircleCleanupMigration.runIfNeeded(firebaseUID: user.uid)

        // Start (or re-target) Firestore listeners for the resolved
        // circle so changes from another supervisor's device flow in.
        if let circleID = resolved?.careCircle?.id {
            await SyncCoordinator.shared.start(careCircleID: circleID)
        } else {
            SyncCoordinator.shared.stop()
        }

        // Now that currentPerson is settled, re-check the persisted act-as
        // state against it: a fresh sign-in whose stored target crosses
        // circles, or an actor who is no longer a supervisor, drops the lens.
        profileSwitch.revalidate()
    }

    /// Called by `CircleSetupView` once the user has created or joined a
    /// care circle. Refreshes `currentPerson` from the local store and
    /// clears the setup gate so AuthGate routes to the dashboard.
    @MainActor
    func completeCircleSetup() async {
        await resolveCurrentPerson()
        needsCircleSetup = (currentPerson == nil)
    }

    func sendPasswordReset(email: String) async throws {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        } catch {
            errorMessage = Self.friendly(error)
            throw error
        }
    }

    // MARK: - Biometric

    var biometricAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    var biometricEnabled: Bool {
        Keychain.getBool(.biometricEnabled)
    }

    var hasSignedInBefore: Bool {
        Keychain.get(.lastEmail) != nil
    }

    var savedEmail: String? {
        Keychain.get(.lastEmail)
    }

    func setBiometric(enabled: Bool) {
        Keychain.setBool(enabled, for: .biometricEnabled)
        if !enabled { Keychain.delete(.idToken) }
    }

    func biometricLogin() async throws {
        let context = LAContext()
        var evalError: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evalError)

        #if DEBUG
        let typeName = Self.describe(context.biometryType)
        if let evalError {
            print("[AUTH-DEBUG] biometric: type=\(typeName), canEvaluate=\(canEvaluate), error.domain=\(evalError.domain), error.code=\(evalError.code), desc=\(evalError.localizedDescription)")
        } else {
            print("[AUTH-DEBUG] biometric: type=\(typeName), canEvaluate=\(canEvaluate)")
        }
        #endif

        guard canEvaluate else {
            errorMessage = AuthError.biometricUnavailable.localizedDescription
            throw AuthError.biometricUnavailable
        }

        do {
            let ok = try await evaluate(context: context, reason: "Sign in to Dosely")
            guard ok else {
                errorMessage = AuthError.biometricFailed.localizedDescription
                throw AuthError.biometricFailed
            }
        } catch let error as AuthError {
            throw error
        } catch {
            #if DEBUG
            let ns = error as NSError
            print("[AUTH-DEBUG] evaluatePolicy threw: domain=\(ns.domain), code=\(ns.code), desc=\(ns.localizedDescription)")
            #endif
            errorMessage = AuthError.biometricFailed.localizedDescription
            throw AuthError.biometricFailed
        }

        // Successful biometric check. We deliberately do NOT touch Firebase —
        // unlocking is purely a local concern. If `currentUser` is non-nil,
        // AuthGate will show TodayView. If it isn't (Firebase session went
        // away independently), the unlock is harmless and LoginView remains;
        // the view surfaces a "sign in with your password" hint.
        if let user = Auth.auth().currentUser {
            await refreshAndStoreToken(for: user)
            self.currentUser = user
        }
        unlock()
    }

    private func evaluate(context: LAContext, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
                if let error { cont.resume(throwing: error) }
                else         { cont.resume(returning: success) }
            }
        }
    }

    private static func describe(_ type: LABiometryType) -> String {
        switch type {
        case .none:    return "none"
        case .touchID: return "touchID"
        case .faceID:  return "faceID"
        @unknown default: return "unknown(\(type.rawValue))"
        }
    }

    // MARK: - Helpers

    private func refreshAndStoreToken(for user: FirebaseAuth.User) async {
        do {
            let token = try await user.getIDToken(forcingRefresh: true)
            Keychain.set(token, for: .idToken)
        } catch {
            // Non-fatal: token refresh failure doesn't block the user.
        }
    }

    static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        #if DEBUG
        print("[AUTH-DEBUG] domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            print("[AUTH-DEBUG]   underlying: domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
        }
        #endif

        switch ns.code {
        case AuthErrorCode.emailAlreadyInUse.rawValue:
            return "An account with this email already exists."
        case AuthErrorCode.invalidEmail.rawValue:
            return "That email address isn't valid."
        case AuthErrorCode.weakPassword.rawValue:
            return "Please choose a stronger password — at least 6 characters."
        case AuthErrorCode.wrongPassword.rawValue,
             AuthErrorCode.invalidCredential.rawValue:
            return "Wrong email or password."
        case AuthErrorCode.userNotFound.rawValue:
            return "No account found with this email."
        case AuthErrorCode.userDisabled.rawValue:
            return "This account has been disabled."
        case AuthErrorCode.networkError.rawValue:
            return "Network error. Please check your connection."
        case AuthErrorCode.tooManyRequests.rawValue:
            return "Too many attempts. Please try again later."
        case AuthErrorCode.operationNotAllowed.rawValue:
            return "Email sign-in isn't enabled for this Firebase project. Enable it in the Firebase console under Authentication → Sign-in method."
        case AuthErrorCode.missingEmail.rawValue:
            return "Please enter your email address."
        case AuthErrorCode.accountExistsWithDifferentCredential.rawValue:
            return "An account exists with a different sign-in method for this email."
        case AuthErrorCode.internalError.rawValue:
            return "Firebase encountered an internal error. Please try again."
        default:
            if let authError = error as? AuthError { return authError.localizedDescription }
            #if DEBUG
            return "Auth error (code \(ns.code)). Check console for details."
            #else
            return "Something went wrong. Please try again."
            #endif
        }
    }

    func dismissError() { errorMessage = nil }
}
