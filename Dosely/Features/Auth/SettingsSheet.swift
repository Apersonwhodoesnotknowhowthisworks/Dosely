import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var biometricOn: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    accountSection
                    if authService.biometricAvailable { biometricSection }
                    Spacer()
                    Button(action: signOut) {
                        Text("Sign out")
                            .dsBodyLarge()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .background(Color.dsDanger)
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .accessibilityLabel("Sign out of Dosely")
                }
                .padding(DSSpacing.lg)
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close settings")
                }
            }
            .onAppear {
                biometricOn = authService.biometricEnabled
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("Signed in as")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
            Text(authService.currentUser?.email ?? "—")
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private var biometricSection: some View {
        Toggle(isOn: Binding(
            get: { biometricOn },
            set: { newValue in
                biometricOn = newValue
                authService.setBiometric(enabled: newValue)
            }
        )) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("Use Face ID")
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                Text("Quick sign-in next time you open Dosely.")
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.dsPrimary)
        .padding(DSSpacing.md)
        .frame(minHeight: DSSpacing.minTapTarget)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
        .accessibilityLabel("Enable Face ID for quick access")
    }

    private func signOut() {
        authService.signOut()
        dismiss()
    }
}
