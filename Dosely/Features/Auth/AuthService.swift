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

    private static let lockedKey = "is_locally_locked"
    private var authHandle: AuthStateDidChangeListenerHandle?

    init() {
        UserDefaults.standard.register(defaults: [Self.lockedKey: true])
        self.isLocallyLocked = UserDefaults.standard.bool(forKey: Self.lockedKey)
        self.currentUser = Auth.auth().currentUser
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
        SyncCoordinator.shared.stop()
        lock()
    }

    // MARK: - Person resolution

    /// Resolves the local Person for the current Firebase user. If no
    /// Person exists yet (fresh signup), bootstraps a default CareCircle
    /// + supervisor as a stopgap until Prompt 14's welcome screen lands.
    /// Also runs the v1 care-circle migration on first invocation, the
    /// one-shot Firestore upload migration for legacy local-only data,
    /// and starts the SyncCoordinator so cross-device updates land.
    @MainActor
    func resolveCurrentPerson() async {
        guard let user = currentUser else {
            currentPerson = nil
            needsCircleSetup = false
            SyncCoordinator.shared.stop()
            return
        }
        let displayName = user.displayName?.isEmpty == false
            ? user.displayName!
            : (user.email ?? "Me")
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"

        // The migration only auto-bootstraps a circle for legacy data
        // (Medications/DoseLogs without a personID). For brand-new
        // accounts it returns nil and we route to CircleSetupView.
        let resolved = await CareCircleMigration.runIfNeeded(
            firebaseUID: user.uid,
            displayName: displayName,
            languagePreference: lang
        )
        currentPerson = resolved
        needsCircleSetup = (resolved == nil)

        // First Firestore-aware launch on a device with pre-existing
        // local data: upload it once, then let listeners take over.
        await FirestoreUploadMigration.runIfNeeded(firebaseUID: user.uid)

        // Split legacy "supervisor" rows into primary/secondary and
        // stamp `CareCircle.primarySupervisorPersonID`. Idempotent via
        // a UserDefaults flag; runs once per device.
        await PrimaryRoleMigration.runIfNeeded()

        // Start (or re-target) Firestore listeners for the resolved
        // circle so changes from another supervisor's device flow in.
        if let circleID = resolved?.careCircle?.id {
            await SyncCoordinator.shared.start(careCircleID: circleID)
        } else {
            SyncCoordinator.shared.stop()
        }
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
