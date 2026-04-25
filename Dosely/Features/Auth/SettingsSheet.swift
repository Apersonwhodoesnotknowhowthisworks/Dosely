import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var language: String = ""
    @State private var biometricOn: Bool = false
    @State private var showingLanguagePicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    accountSection
                    languageSection
                    if authService.biometricAvailable { biometricSection }
                    Spacer()
                    Button(action: signOut) {
                        Text("settings.signout")
                            .dsBodyLarge()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .background(Color.dsDanger)
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .accessibilityLabel(Text("settings.signout"))
                }
                .padding(DSSpacing.lg)
            }
            .navigationTitle(Text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) { dismiss() }
                        .accessibilityLabel(Text("settings.close"))
                }
            }
            .onAppear {
                biometricOn = authService.biometricEnabled
            }
            .sheet(isPresented: $showingLanguagePicker) {
                LanguagePickerView(
                    onPicked: { picked in
                        language = picked
                        showingLanguagePicker = false
                    },
                    showCancel: true,
                    onCancel: { showingLanguagePicker = false }
                )
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("settings.signedinas")
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

    private var languageSection: some View {
        Button(action: { showingLanguagePicker = true }) {
            HStack {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text("settings.language.row")
                        .dsBodyLarge()
                        .foregroundColor(.dsTextPrimary)
                    Text(currentLanguageDisplay)
                        .dsBodyRegular()
                        .foregroundColor(.dsTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.dsTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(DSSpacing.md)
            .frame(minHeight: DSSpacing.minTapTarget)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel(Text("settings.language.title"))
        .accessibilityValue(currentLanguageDisplay)
    }

    private var currentLanguageDisplay: String {
        switch language {
        case "pa": return L("languagepicker.punjabi")
        default:   return L("languagepicker.english")
        }
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
                Text("settings.faceid.title")
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                Text("settings.faceid.subtitle")
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
        .accessibilityLabel(Text("settings.faceid.title"))
    }

    private func signOut() {
        authService.signOut()
        dismiss()
    }
}
