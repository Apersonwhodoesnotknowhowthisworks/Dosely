import SwiftUI

struct PasswordResetView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var sent = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    if sent {
                        sentState
                    } else {
                        formState
                    }
                    Spacer()
                }
                .padding(DSSpacing.lg)

                if authService.isLoading {
                    ProgressView().scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.15).ignoresSafeArea())
                }
            }
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel password reset")
                }
            }
            .onAppear {
                if let saved = authService.savedEmail, email.isEmpty { email = saved }
                focused = true
            }
        }
    }

    private var formState: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("Enter the email you signed up with and we'll send you a reset link.")
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let msg = authService.errorMessage {
                Text(msg)
                    .dsBodyRegular()
                    .foregroundColor(.white)
                    .padding(DSSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.dsDanger)
                    .cornerRadius(DSSpacing.rMd)
            }

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
                .focused($focused)
                .accessibilityLabel("Email address")

            Button(action: { Task { await send() } }) {
                Text("Send reset link")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(canSubmit ? Color.dsPrimary : Color.gray.opacity(0.4))
                    .cornerRadius(DSSpacing.rMd)
            }
            .disabled(!canSubmit)
            .accessibilityLabel("Send password reset link")
        }
    }

    private var sentState: some View {
        VStack(alignment: .center, spacing: DSSpacing.lg) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 56))
                .foregroundColor(.dsPrimary)
                .accessibilityHidden(true)
            Text("Check your email")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
            Text("We've sent a password reset link to \(email).")
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { dismiss() }) {
                Text("OK")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.top, DSSpacing.xxl)
        .frame(maxWidth: .infinity)
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !authService.isLoading
    }

    private func send() async {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        do {
            try await authService.sendPasswordReset(email: trimmed)
            sent = true
        } catch {
            // service sets errorMessage
        }
    }
}
