import SwiftUI

/// Detail editor for a Person in the supervisor's care circle. Shows
/// name/photo/language fields, a PIN-reset action for device clients, a
/// role-flip action for clients, and a remove-from-circle action with
/// confirmation. Supervisor rows are read-only here — adding or removing
/// supervisors goes through the join code flow.
struct PersonDetailView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var language: String
    @State private var newPin: String = ""
    @State private var showingPinResetAlert = false
    @State private var showingPromoteAlert = false
    @State private var promoteToRole: String = ""
    @State private var promotePin: String = ""
    @State private var showingRemoveAlert = false
    @State private var errorMessage: String?

    let person: Person
    let personRepo: PersonRepository
    var onChanged: () -> Void

    init(person: Person,
         personRepo: PersonRepository,
         onChanged: @escaping () -> Void) {
        self.person = person
        self.personRepo = personRepo
        self.onChanged = onChanged
        _name = State(initialValue: person.name ?? "")
        _language = State(initialValue: person.languagePreference ?? "en")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    nameSection
                    languageSection

                    if person.role == "device_client" {
                        pinResetSection
                        roleFlipSection(targetRole: "managed_client",
                                        title: L("supervisor.person.demote.title"),
                                        body: L("supervisor.person.demote.body"))
                    } else if person.role == "managed_client" {
                        roleFlipSection(targetRole: "device_client",
                                        title: L("supervisor.person.promote.title"),
                                        body: L("supervisor.person.promote.body"))
                    }

                    if person.role != "supervisor" || canRemoveSupervisor {
                        removeSection
                    }
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(Text(name.isEmpty ? L("supervisor.people.title") : name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) {
                        Task { await saveAndDismiss() }
                    }
                }
            }
            .alert(L("supervisor.person.pinreset.title"),
                   isPresented: $showingPinResetAlert) {
                TextField(L("supervisor.person.pinreset.placeholder"), text: $newPin)
                    .keyboardType(.numberPad)
                Button(L("common.save")) { Task { await resetPin() } }
                Button(L("common.cancel"), role: .cancel) { newPin = "" }
            } message: {
                Text("supervisor.person.pinreset.body")
            }
            .alert(promoteAlertTitle,
                   isPresented: $showingPromoteAlert) {
                if promoteToRole == "device_client" {
                    TextField(L("supervisor.person.pinreset.placeholder"), text: $promotePin)
                        .keyboardType(.numberPad)
                }
                Button(L("common.save"), role: nil) {
                    Task { await flipRole(to: promoteToRole) }
                }
                Button(L("common.cancel"), role: .cancel) { promotePin = "" }
            } message: {
                Text(promoteAlertBody)
            }
            .alert(L("supervisor.person.remove.title"),
                   isPresented: $showingRemoveAlert) {
                Button(L("supervisor.person.remove"), role: .destructive) {
                    Task { await removeFromCircle() }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("supervisor.person.remove.body", name as NSString))
            }
            .alert(L("supervisor.person.error.title"),
                   isPresented: errorBinding) {
                Button(L("common.ok"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("supervisor.person.name").dsCaption().foregroundColor(.dsTextSecondary)
            TextField(L("supervisor.person.name"), text: $name)
                .dsBodyLarge()
                .padding(DSSpacing.md)
                .frame(minHeight: DSSpacing.minTapTarget)
                .background(Color.dsSurface)
                .cornerRadius(DSSpacing.rMd)
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("supervisor.person.language").dsCaption().foregroundColor(.dsTextSecondary)
            Picker(L("supervisor.person.language"), selection: $language) {
                Text("languagepicker.english").tag("en")
                Text("languagepicker.punjabi").tag("pa")
            }
            .pickerStyle(.segmented)
        }
    }

    private var pinResetSection: some View {
        actionCard(
            title: L("supervisor.person.pinreset.title"),
            body: L("supervisor.person.pinreset.body"),
            actionLabel: L("supervisor.person.pinreset.action"),
            action: { showingPinResetAlert = true }
        )
    }

    private func roleFlipSection(targetRole: String, title: String, body: String) -> some View {
        actionCard(title: title, body: body, actionLabel: title) {
            promoteToRole = targetRole
            promotePin = ""
            showingPromoteAlert = true
        }
    }

    private var removeSection: some View {
        Button(action: { showingRemoveAlert = true }) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("supervisor.person.remove")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                Text("supervisor.person.remove.subtitle")
                    .dsCaption()
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.md)
            .background(Color.dsDanger)
            .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel(Text("supervisor.person.remove"))
    }

    private func actionCard(title: String,
                            body: String,
                            actionLabel: String,
                            action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(title).dsBodyLarge().foregroundColor(.dsTextPrimary)
            Text(body)
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(actionLabel)
                    .dsBodyRegular()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel(Text(actionLabel))
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    // MARK: - Actions

    private func saveAndDismiss() async {
        guard let id = person.id else { dismiss(); return }
        await personRepo.updatePerson(id: id,
                                      name: name.isEmpty ? nil : name,
                                      photoData: nil,
                                      language: language)
        onChanged()
        dismiss()
    }

    private func resetPin() async {
        guard let targetID = person.id,
              let actorID = authService.currentPerson?.id else { return }
        let pin = newPin
        newPin = ""
        do {
            try await personRepo.resetPin(personID: targetID,
                                          newPinPlaintext: pin,
                                          actingSupervisorID: actorID)
            onChanged()
        } catch {
            errorMessage = mapError(error)
        }
    }

    private func flipRole(to newRole: String) async {
        guard let targetID = person.id,
              let actorID = authService.currentPerson?.id else { return }
        let pin = promotePin
        promotePin = ""
        do {
            try await personRepo.updatePersonRole(
                personID: targetID,
                newRole: newRole,
                newPinPlaintext: newRole == "device_client" ? pin : nil,
                actingSupervisorID: actorID
            )
            onChanged()
            dismiss()
        } catch {
            errorMessage = mapError(error)
        }
    }

    private func removeFromCircle() async {
        guard let targetID = person.id,
              let actorID = authService.currentPerson?.id else { return }
        do {
            try await personRepo.removePersonFromCircle(personID: targetID,
                                                        actingSupervisorID: actorID)
            onChanged()
            dismiss()
        } catch {
            errorMessage = mapError(error)
        }
    }

    // MARK: - Helpers

    private var canRemoveSupervisor: Bool {
        // The "you can't remove yourself if you're the only supervisor"
        // rule lives in the repository (lastSupervisor); the UI just
        // doesn't surface a remove button on the actor's own row.
        person.id != authService.currentPerson?.id
    }

    private var promoteAlertTitle: String {
        promoteToRole == "device_client"
            ? L("supervisor.person.promote.title")
            : L("supervisor.person.demote.title")
    }

    private var promoteAlertBody: String {
        promoteToRole == "device_client"
            ? L("supervisor.person.promote.body")
            : L("supervisor.person.demote.body")
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func mapError(_ error: Error) -> String {
        guard let err = error as? PersonRepositoryError else {
            return L("supervisor.person.error.generic")
        }
        switch err {
        case .lastSupervisor:        return L("supervisor.person.error.lastsupervisor")
        case .permissionDenied:      return L("supervisor.person.error.permission")
        case .invalidPin:            return L("supervisor.person.error.invalidpin")
        case .invalidRoleTransition: return L("supervisor.person.error.invalidrole")
        case .notFound, .alreadyExists: return L("supervisor.person.error.generic")
        }
    }
}
