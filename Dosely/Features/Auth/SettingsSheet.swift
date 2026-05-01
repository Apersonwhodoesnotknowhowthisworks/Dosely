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
    // Family section state
    @State private var copiedToastVisible = false
    @State private var confirmingRegenerate = false
    @State private var showingLeaveAndJoin = false
    @State private var confirmingLeavePermanently = false
    @State private var lastSupervisorAlertVisible = false
    @State private var primaryPromoteFirstAlertVisible = false
    @State private var familyName: String = ""
    @State private var joinCode: String = ""
    @State private var regenerateErrorVisible = false
    private let careCircleRepo = CareCircleRepository()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        accountSection
                        if isSupervisor { familySection }
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
                if copiedToastVisible {
                    copiedToast
                        .transition(.opacity)
                        .padding(.bottom, DSSpacing.xl)
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
                refreshFamilyState()
            }
            .fullScreenCover(isPresented: $showingLeaveAndJoin) {
                LeaveAndJoinFlow(careCircleRepo: careCircleRepo)
                    .environmentObject(authService)
            }
            .alert(L("settings.family.regenerate.title"),
                   isPresented: $confirmingRegenerate) {
                Button(L("supervisor.circle.regenerate"), role: .destructive) {
                    Task { await regenerateJoinCode() }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text("supervisor.circle.regenerate.body")
            }
            .alert(L("settings.family.leave.permanently.title"),
                   isPresented: $confirmingLeavePermanently) {
                Button(L("settings.family.leave.permanently.action"),
                       role: .destructive) {
                    Task { await leavePermanently() }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text("settings.family.leave.permanently.body")
            }
            .alert(L("settings.family.lastsupervisor.title"),
                   isPresented: $lastSupervisorAlertVisible) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text("settings.family.lastsupervisor.body")
            }
            .alert(L("settings.family.lastsupervisor.title"),
                   isPresented: $primaryPromoteFirstAlertVisible) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text("circle.leave.error.primarypromotefirst")
            }
            .alert(L("settings.family.regenerate.error.title"),
                   isPresented: $regenerateErrorVisible) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text("settings.family.regenerate.error.body")
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

    // MARK: - Family

    private var familySection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("settings.family.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)

            row(label: L("supervisor.circle.name"),
                value: familyName.isEmpty ? "—" : familyName)

            joinCodeRow

            if isPrimary {
                Button(action: { confirmingRegenerate = true }) {
                    actionRow(label: L("supervisor.circle.regenerate"),
                              tint: .dsWarning)
                }
                .accessibilityLabel(Text("supervisor.circle.regenerate"))
            }

            Divider().padding(.vertical, DSSpacing.xs)

            Button(action: { handleLeaveAndJoinTap() }) {
                actionRow(label: L("settings.family.leave.andjoin"),
                          subtitle: L("settings.family.leave.andjoin.subtitle"),
                          tint: .dsDanger)
            }
            .accessibilityLabel(Text("settings.family.leave.andjoin"))

            Button(action: { handleLeavePermanentlyTap() }) {
                actionRow(label: L("settings.family.leave.permanently"),
                          subtitle: L("settings.family.leave.permanently.subtitle"),
                          tint: .dsDanger)
            }
            .accessibilityLabel(Text("settings.family.leave.permanently"))
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private var joinCodeRow: some View {
        HStack(alignment: .center, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("supervisor.circle.joincode")
                    .dsCaption()
                    .foregroundColor(.dsTextSecondary)
                Text(joinCode.isEmpty ? "—" : joinCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(.dsTextPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copyJoinCode) {
                Label(L("settings.family.copy"), systemImage: "doc.on.doc")
                    .dsBodyRegular()
                    .foregroundColor(.dsPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSSpacing.rMd)
                            .stroke(Color.dsPrimary, lineWidth: 1.5)
                    )
            }
            .accessibilityLabel(Text("settings.family.copy"))
        }
    }

    private func row(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(label).dsCaption().foregroundColor(.dsTextSecondary)
            Text(value)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .lineLimit(1)
        }
    }

    private func actionRow(label: String,
                           subtitle: String? = nil,
                           tint: Color) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(label)
                .dsBodyLarge()
                .foregroundColor(tint)
            if let subtitle {
                Text(subtitle)
                    .dsCaption()
                    .foregroundColor(.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DSSpacing.sm)
    }

    private var copiedToast: some View {
        Text("settings.family.copied")
            .dsBodyRegular()
            .foregroundColor(.white)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            .background(Color.dsTextPrimary.opacity(0.9))
            .cornerRadius(DSSpacing.rLg)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Family — actions

    private var isSupervisor: Bool {
        Roles.isAnySupervisor(authService.currentPerson?.role)
    }

    private var isPrimary: Bool {
        Roles.isPrimary(authService.currentPerson)
    }

    private func refreshFamilyState() {
        guard let circle = authService.currentPerson?.careCircle else {
            familyName = ""
            joinCode = ""
            return
        }
        familyName = circle.name ?? ""
        joinCode = circle.joinCode ?? ""
    }

    private func copyJoinCode() {
        guard !joinCode.isEmpty else { return }
        UIPasteboard.general.string = joinCode
        withAnimation(.easeInOut(duration: 0.2)) { copiedToastVisible = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { copiedToastVisible = false }
            }
        }
    }

    private func regenerateJoinCode() async {
        guard let circleID = authService.currentPerson?.careCircle?.id,
              let actorID = authService.currentPerson?.id else { return }
        do {
            let newCode = try await careCircleRepo.regenerateJoinCode(
                careCircleID: circleID, actorPersonID: actorID
            )
            await MainActor.run { joinCode = newCode }
        } catch {
            // Couldn't write to Firestore. The local Core Data row is
            // intentionally left untouched, so the displayed code stays
            // the last one Firestore confirmed. Tell the user instead of
            // silently pretending the regenerate worked.
            await MainActor.run { regenerateErrorVisible = true }
        }
    }

    private func handleLeaveAndJoinTap() {
        if isLastSupervisor() {
            lastSupervisorAlertVisible = true
        } else {
            showingLeaveAndJoin = true
        }
    }

    private func handleLeavePermanentlyTap() {
        if isLastSupervisor() {
            lastSupervisorAlertVisible = true
        } else {
            confirmingLeavePermanently = true
        }
    }

    private func isLastSupervisor() -> Bool {
        guard let person = authService.currentPerson,
              let circle = person.careCircle else { return false }
        let people = (circle.people as? Set<Person>) ?? []
        let otherSupervisors = people.filter {
            Roles.isAnySupervisor($0.role) && $0.id != person.id
        }
        return otherSupervisors.isEmpty
    }

    private func leavePermanently() async {
        guard let id = authService.currentPerson?.id else { return }
        let result = await careCircleRepo.leaveCircle(supervisorPersonID: id)
        switch result {
        case .success:
            await authService.completeCircleSetup()
            dismiss()
        case .failure(.lastSupervisor):
            lastSupervisorAlertVisible = true
        case .failure(.primaryMustPromoteFirst):
            primaryPromoteFirstAlertVisible = true
        case .failure:
            // notFound / notMember are pathological here; ignore silently.
            break
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

}
