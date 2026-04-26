import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var language: String = ""
    @AppStorage("force_light_mode") private var forceLightMode: Bool = false
    @State private var biometricOn: Bool = false
    @State private var showingLanguagePicker = false
    @State private var confirmingLockSignOut = false
    @State private var confirmingFullSignOut = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        accountSection
                        languageSection
                        lightModeSection
                        if authService.biometricAvailable { biometricSection }
                        VStack(spacing: DSSpacing.md) {
                            lockSignOutButton
                            fullSignOutButton
                        }
                        .padding(.top, DSSpacing.lg)
                    }
                    .padding(DSSpacing.lg)
                }
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
            .alert(L("settings.signout.confirm.lock.title"),
                   isPresented: $confirmingLockSignOut) {
                Button(L("settings.signout.lock.title"), role: .destructive) {
                    authService.signOut()
                    dismiss()
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text("settings.signout.lock.subtitle")
            }
            .alert(L("settings.signout.confirm.complete.title"),
                   isPresented: $confirmingFullSignOut) {
                Button(L("settings.signout.complete.title"), role: .destructive) {
                    authService.signOutCompletely()
                    dismiss()
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text("settings.signout.complete.subtitle")
            }
        }
    }

    private var lockSignOutButton: some View {
        Button(action: { confirmingLockSignOut = true }) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("settings.signout.lock.title")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                Text("settings.signout.lock.subtitle")
                    .dsCaption()
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.md)
            .background(Color.dsWarning)
            .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel(Text("settings.signout.lock.title"))
    }

    private var fullSignOutButton: some View {
        Button(action: { confirmingFullSignOut = true }) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("settings.signout.complete.title")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                Text("settings.signout.complete.subtitle")
                    .dsCaption()
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.md)
            .background(Color.dsDanger)
            .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel(Text("settings.signout.complete.title"))
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

    private var lightModeSection: some View {
        Toggle(isOn: $forceLightMode) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("settings.lightmode.title")
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                Text("settings.lightmode.subtitle")
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
        .accessibilityLabel(Text("settings.lightmode.title"))
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

}
