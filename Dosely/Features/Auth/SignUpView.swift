import SwiftUI

struct SignUpView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var showBiometricPrompt = false
    @FocusState private var focusedField: Field?

    enum Field { case email, password, confirm }

    var body: some View {
        ZStack {
            Color.dsBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    VStack(alignment: .leading, spacing: DSSpacing.sm) {
                        Text("auth.signup.title")
                            .dsTitleLarge()
                            .foregroundColor(.dsTextPrimary)
                        Text("auth.signup.subtitle")
                            .dsBodyRegular()
                            .foregroundColor(.dsTextSecondary)
                    }

                    if let msg = authService.errorMessage {
                        Text(msg)
                            .dsBodyRegular()
                            .foregroundColor(.white)
                            .padding(DSSpacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.dsDanger)
                            .cornerRadius(DSSpacing.rMd)
                    }

                    VStack(spacing: DSSpacing.md) {
                        field(L("auth.email.placeholder"), text: $email, secure: false,
                              keyboard: .emailAddress, content: .emailAddress,
                              focus: .email, next: .password)
                        field(L("auth.password.placeholder"), text: $password, secure: true,
                              content: .newPassword, focus: .password, next: .confirm)
                        field(L("auth.signup.confirm.placeholder"), text: $confirm, secure: true,
                              content: .newPassword, focus: .confirm, next: nil)
                    }

                    Button(action: { Task { await createAccount() } }) {
                        Text("auth.signup.button")
                            .dsBodyLarge()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .background(canSubmit ? Color.dsPrimary : Color.gray.opacity(0.4))
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .disabled(!canSubmit)
                    .accessibilityLabel(Text("auth.signup.button"))
                }
                .padding(DSSpacing.lg)
            }

            if authService.isLoading {
                ProgressView().scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.15).ignoresSafeArea())
            }
        }
        .navigationTitle(Text("auth.createaccount"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L("auth.signup.faceid.title"), isPresented: $showBiometricPrompt) {
            Button(L("common.yes")) {
                authService.setBiometric(enabled: true)
            }
            Button(L("common.notnow"), role: .cancel) {
                authService.setBiometric(enabled: false)
            }
        } message: {
            Text("auth.signup.faceid.message")
        }
    }

    @ViewBuilder
    private func field(_ placeholder: String,
                       text: Binding<String>,
                       secure: Bool,
                       keyboard: UIKeyboardType = .default,
                       content: UITextContentType,
                       focus: Field,
                       next: Field?) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .keyboardType(keyboard)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .dsBodyLarge()
        .textContentType(content)
        .padding(DSSpacing.md)
        .frame(minHeight: DSSpacing.minTapTarget)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
        .focused($focusedField, equals: focus)
        .submitLabel(next == nil ? .go : .next)
        .onSubmit {
            if let next = next { focusedField = next }
            else { Task { await createAccount() } }
        }
        .accessibilityLabel(placeholder)
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        password.count >= 6 &&
        !confirm.isEmpty &&
        !authService.isLoading
    }

    private func createAccount() async {
        focusedField = nil
        guard password == confirm else {
            authService.errorMessage = AuthError.passwordMismatch.localizedDescription
            return
        }
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        do {
            try await authService.signUp(email: trimmed, password: password)
            if authService.biometricAvailable {
                showBiometricPrompt = true
            }
        } catch {
            // errorMessage set by service
        }
    }
}
