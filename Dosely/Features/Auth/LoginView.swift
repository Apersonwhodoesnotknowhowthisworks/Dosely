import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authService: AuthService

    @State private var email = ""
    @State private var password = ""
    @State private var showingReset = false
    @State private var showingSignUp = false
    @FocusState private var focusedField: Field?

    enum Field { case email, password }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        if let msg = authService.errorMessage {
                            ErrorBanner(message: msg) { authService.dismissError() }
                        }

                        VStack(alignment: .leading, spacing: DSSpacing.sm) {
                            Text("Welcome to Dosely")
                                .dsTitleLarge()
                                .foregroundColor(.dsTextPrimary)
                            Text("Sign in to keep your medications safe.")
                                .dsBodyRegular()
                                .foregroundColor(.dsTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: DSSpacing.md) {
                            emailField
                            passwordField
                        }

                        Button(action: { Task { await signIn() } }) {
                            Text("Sign in")
                                .dsBodyLarge()
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                                .background(canSubmit ? Color.dsPrimary : Color.gray.opacity(0.4))
                                .cornerRadius(DSSpacing.rMd)
                        }
                        .disabled(!canSubmit)
                        .accessibilityLabel("Sign in")

                        if showFaceIDButton {
                            Button(action: { Task { await biometric() } }) {
                                Label("Use Face ID", systemImage: "faceid")
                                    .dsBodyLarge()
                                    .foregroundColor(.dsPrimary)
                                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DSSpacing.rMd)
                                            .stroke(Color.dsPrimary, lineWidth: 1.5)
                                    )
                            }
                            .accessibilityLabel("Sign in with Face ID")
                        }

                        Button("Forgot password?") { showingReset = true }
                            .dsBodyLarge()
                            .foregroundColor(.dsPrimary)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .accessibilityLabel("Reset forgotten password")

                        Spacer(minLength: DSSpacing.xl)

                        HStack(spacing: DSSpacing.xs) {
                            Text("New here?")
                                .dsBodyRegular()
                                .foregroundColor(.dsTextSecondary)
                            Button("Create an account") { showingSignUp = true }
                                .dsBodyLarge()
                                .foregroundColor(.dsPrimary)
                                .accessibilityLabel("Create a new Dosely account")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(DSSpacing.lg)
                }

                if authService.isLoading {
                    ProgressView().scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.15).ignoresSafeArea())
                }
            }
            .navigationDestination(isPresented: $showingSignUp) { SignUpView() }
            .sheet(isPresented: $showingReset) { PasswordResetView() }
            .onAppear {
                if let saved = authService.savedEmail, email.isEmpty { email = saved }
            }
        }
    }

    private var emailField: some View {
        TextField("Email", text: $email)
            .dsBodyLarge()
            .keyboardType(.emailAddress)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .textContentType(.emailAddress)
            .padding(DSSpacing.md)
            .frame(minHeight: DSSpacing.minTapTarget)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
            .focused($focusedField, equals: .email)
            .submitLabel(.next)
            .onSubmit { focusedField = .password }
            .accessibilityLabel("Email address")
    }

    private var passwordField: some View {
        SecureField("Password", text: $password)
            .dsBodyLarge()
            .textContentType(.password)
            .padding(DSSpacing.md)
            .frame(minHeight: DSSpacing.minTapTarget)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit { Task { await signIn() } }
            .accessibilityLabel("Password")
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !authService.isLoading
    }

    private var showFaceIDButton: Bool {
        authService.biometricAvailable && authService.hasSignedInBefore
    }

    private func signIn() async {
        focusedField = nil
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        do { try await authService.signIn(email: trimmed, password: password) }
        catch { /* errorMessage set in service */ }
    }

    private func biometric() async {
        do { try await authService.biometricLogin() }
        catch { /* error surfaces via localized error through service if thrown before */ }
    }
}

private struct ErrorBanner: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
                .accessibilityHidden(true)
            Text(message)
                .dsBodyRegular()
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundColor(.white)
                    .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding(DSSpacing.md)
        .background(Color.dsDanger)
        .cornerRadius(DSSpacing.rMd)
    }
}
