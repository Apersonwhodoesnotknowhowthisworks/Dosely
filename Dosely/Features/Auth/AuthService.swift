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

    private var authHandle: AuthStateDidChangeListenerHandle?

    init() {
        self.currentUser = Auth.auth().currentUser
        self.authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.currentUser = user }
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
            self.needsDisclaimer = !UserDefaults.standard.bool(forKey: "disclaimer_accepted")
        } catch {
            errorMessage = Self.friendly(error)
            throw error
        }
    }

    func signIn(email: String, password: String) async throws {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            Keychain.set(email, for: .lastEmail)
            await refreshAndStoreToken(for: result.user)
        } catch {
            errorMessage = Self.friendly(error)
            throw error
        }
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            Keychain.delete(.idToken)
        } catch {
            errorMessage = Self.friendly(error)
        }
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

        // Firebase persists its own session across app launches. If it's still
        // here, biometric is effectively a local gate — refresh the token and go.
        if let user = Auth.auth().currentUser {
            await refreshAndStoreToken(for: user)
            self.currentUser = user
            return
        }
        // If the user explicitly signed out, we can't recover without a password.
        errorMessage = AuthError.sessionExpired.localizedDescription
        throw AuthError.sessionExpired
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
