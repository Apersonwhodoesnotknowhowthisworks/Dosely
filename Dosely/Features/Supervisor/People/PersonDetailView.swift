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
    @State private var showingPromoteToPrimaryAlert = false
    @State private var errorMessage: String?
    @State private var personMedications: [Medication] = []
    @State private var medicationsLoaded = false
    @State private var showingAddMedication = false
    @State private var showingMedicalIDEditor = false
    @State private var showingMedicalIDViewer = false
    @State private var showingDemoteSheet = false
    @State private var isDemoting = false
    @State private var showingSwitchSheet = false
    @State private var isSwitching = false

    let person: Person
    let personRepo: PersonRepository
    let medicationRepo: MedicationRepository
    var onChanged: () -> Void

    private var actorIsPrimary: Bool {
        guard let actor = authService.currentPerson,
              let circle = actor.careCircle,
              let me = actor.id else { return false }
        if let primaryID = circle.primarySupervisorPersonID {
            return primaryID == me
        }
        return Roles.isPrimarySupervisor(actor.role)
    }

    private var targetIsAnotherSupervisor: Bool {
        Roles.isAnySupervisor(person.role) && person.id != authService.currentPerson?.id
    }

    private var showDemoteSection: Bool {
        Self.shouldShowDemoteSection(
            targetRole: person.role,
            targetPersonID: person.id,
            actorPersonID: authService.currentPerson?.id,
            primarySupervisorPersonID: authService.currentPerson?.careCircle?.primarySupervisorPersonID,
            actorIsPrimary: actorIsPrimary
        )
    }

    // Gated on `currentPerson` (not `actorPerson`) deliberately: eligibility
    // to START a switch belongs to the signed-in supervisor, never to a lens.
    private var showSwitchToViewSection: Bool {
        Self.shouldShowSwitchToView(
            targetRole: person.role,
            targetPersonID: person.id,
            actorPersonID: authService.currentPerson?.id,
            actorIsPrimary: actorIsPrimary
        )
    }

    private var primaryName: String? {
        guard let circle = authService.currentPerson?.careCircle,
              let primaryID = circle.primarySupervisorPersonID,
              let people = circle.people as? Set<Person> else { return nil }
        return people.first(where: { $0.id == primaryID })?.name
    }

    init(person: Person,
         personRepo: PersonRepository,
         medicationRepo: MedicationRepository = MedicationRepository(),
         onChanged: @escaping () -> Void) {
        self.person = person
        self.personRepo = personRepo
        self.medicationRepo = medicationRepo
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

                    if !Roles.isAnySupervisor(person.role) {
                        medicationsSection
                        medicalIDSection
                    }

                    if actorIsPrimary {
                        if showSwitchToViewSection {
                            switchToViewSection
                        }

                        if person.role == Roles.deviceClient {
                            pinResetSection
                            roleFlipSection(targetRole: Roles.managedClient,
                                            title: L("supervisor.person.demote.title"),
                                            body: L("supervisor.person.demote.body"))
                        } else if person.role == Roles.managedClient {
                            roleFlipSection(targetRole: Roles.deviceClient,
                                            title: L("supervisor.person.promote.title"),
                                            body: L("supervisor.person.promote.body"))
                        }

                        if targetIsAnotherSupervisor {
                            promoteToPrimaryRow
                        }

                        if showDemoteSection {
                            demoteRoleSection
                        }

                        if !Roles.isAnySupervisor(person.role) || canRemoveSupervisor {
                            removeSection
                        }
                    } else {
                        readOnlyNotice
                    }
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(Text(name.isEmpty ? L("supervisor.people.title") : name))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: person.id) { await loadMedications() }
            .sheet(isPresented: $showingAddMedication) {
                AddMedicationFlow(repository: medicationRepo) {
                    Task {
                        await loadMedications()
                        onChanged()
                    }
                }
                .environmentObject(authService)
                .environment(\.supervisorTargetPersonID, person.id)
            }
            .sheet(isPresented: $showingMedicalIDEditor) {
                EditMedicalIDView()
                    .environmentObject(authService)
                    .environment(\.supervisorTargetPersonID, person.id)
            }
            .sheet(isPresented: $showingMedicalIDViewer) {
                EmergencyMedicalIDView(person: person)
            }
            .sheet(isPresented: $showingDemoteSheet) {
                DemoteToManagedClientSheet(
                    personName: name.isEmpty ? (person.name ?? "") : name,
                    isWorking: isDemoting,
                    onConfirm: { Task { await demoteToManagedClient() } },
                    onCancel: { showingDemoteSheet = false }
                )
            }
            .sheet(isPresented: $showingSwitchSheet) {
                ProfileSwitchConfirmSheet(
                    personName: name.isEmpty ? (person.name ?? "") : name,
                    isWorking: isSwitching,
                    onConfirm: { Task { await switchToTargetView() } },
                    onCancel: { showingSwitchSheet = false }
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) {
                        Task { await saveAndDismiss() }
                    }
                    .disabled(!actorIsPrimary)
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
            .alert(Text(L("supervisor.promote.confirm.title", name as NSString)),
                   isPresented: $showingPromoteToPrimaryAlert) {
                Button(L("supervisor.promote.confirm.action"), role: .destructive) {
                    Task { await makePrimary() }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("supervisor.promote.confirm.body", name as NSString))
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
            if actorIsPrimary {
                TextField(L("supervisor.person.name"), text: $name)
                    .dsBodyLarge()
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
            } else {
                Text(name)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
            }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("supervisor.person.language").dsCaption().foregroundColor(.dsTextSecondary)
            if actorIsPrimary {
                Picker(L("supervisor.person.language"), selection: $language) {
                    Text("languagepicker.english").tag("en")
                    Text("languagepicker.punjabi").tag("pa")
                }
                .pickerStyle(.segmented)
            } else {
                Text(language == "pa"
                     ? L("languagepicker.punjabi")
                     : L("languagepicker.english"))
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
            }
        }
    }

    private var medicationsSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("supervisor.person.medications.title")
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)

            if !medicationsLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if personMedications.isEmpty {
                Text("supervisor.person.medications.empty")
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: DSSpacing.xs) {
                    ForEach(personMedications, id: \.id) { med in
                        medicationRow(med)
                    }
                }
            }

            if actorIsPrimary {
                Button(action: { showingAddMedication = true }) {
                    HStack(spacing: DSSpacing.sm) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.white)
                            .accessibilityHidden(true)
                        Text("supervisor.person.medications.add")
                            .dsBodyLarge()
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
                }
                .accessibilityLabel(Text("supervisor.person.medications.add"))
            }
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    private func medicationRow(_ med: Medication) -> some View {
        HStack(spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(med.name ?? "")
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                if let dose = med.dose, !dose.isEmpty {
                    Text(dose)
                        .dsCaption()
                        .foregroundColor(.dsTextSecondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget, alignment: .leading)
        .padding(.vertical, DSSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var medicalIDSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("supervisor.person.medicalid.title")
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
            Text("supervisor.person.medicalid.subtitle")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { showingMedicalIDViewer = true }) {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: "heart.text.square.fill")
                        .foregroundColor(.dsDanger)
                        .accessibilityHidden(true)
                    Text("emergency.medicalid.view.action")
                        .dsBodyLarge()
                        .foregroundColor(.dsTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.dsTextSecondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("emergency.medicalid.view.action"))
            Button(action: { showingMedicalIDEditor = true }) {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: "cross.case.fill")
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                    Text("supervisor.person.medicalid.edit")
                        .dsBodyLarge()
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                .background(Color.dsDanger)
                .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel(Text("supervisor.person.medicalid.edit"))
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    private var promoteToPrimaryRow: some View {
        Button(action: { showingPromoteToPrimaryAlert = true }) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("supervisor.promote.row")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                Text("supervisor.promote.row.subtitle")
                    .dsCaption()
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.md)
            .background(Color.dsPrimary)
            .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel(Text("supervisor.promote.row"))
    }

    private var switchToViewSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Button(action: { showingSwitchSheet = true }) {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                    Text(L("profileswitch.affordance.button.title",
                           (name.isEmpty ? (person.name ?? "") : name) as NSString))
                        .dsBodyLarge()
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white.opacity(0.9))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget, alignment: .leading)
                .padding(DSSpacing.md)
                .background(Color.dsPrimary)
                .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel(Text(L("profileswitch.affordance.button.title",
                                       (name.isEmpty ? (person.name ?? "") : name) as NSString)))
            Text(L("profileswitch.affordance.caption",
                   (name.isEmpty ? (person.name ?? "") : name) as NSString))
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    private var demoteRoleSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("people.demote.section.title")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
            Button(action: { showingDemoteSheet = true }) {
                HStack(spacing: DSSpacing.sm) {
                    Text("people.demote.button.title")
                        .dsBodyLarge()
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white.opacity(0.9))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget, alignment: .leading)
                .padding(DSSpacing.md)
                .background(Color.dsWarning)
                .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel(Text("people.demote.button.title"))
            Text("people.demote.section.subtitle")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    private var readOnlyNotice: some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Image(systemName: "lock.fill")
                .foregroundColor(.dsTextSecondary)
                .accessibilityHidden(true)
            Text(readOnlyMessage)
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
        .accessibilityElement(children: .combine)
    }

    private var readOnlyMessage: String {
        if let name = primaryName {
            return L("supervisor.readonly.notice", name as NSString)
        }
        return L("supervisor.readonly.notice.unknown")
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

    private func loadMedications() async {
        guard let id = person.id else {
            personMedications = []
            medicationsLoaded = true
            return
        }
        let meds = await medicationRepo.fetchAllMedications(for: id)
        personMedications = meds
        medicationsLoaded = true
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
                newPinPlaintext: newRole == Roles.deviceClient ? pin : nil,
                actingSupervisorID: actorID
            )
            onChanged()
            dismiss()
        } catch {
            errorMessage = mapError(error)
        }
    }

    private func makePrimary() async {
        guard let targetID = person.id,
              let actorID = authService.currentPerson?.id else { return }
        do {
            try await personRepo.promoteToPrimary(
                targetPersonID: targetID,
                actorPersonID: actorID
            )
            onChanged()
            dismiss()
        } catch {
            // Distinct error codes per error-collapse convention —
            // see build_log April 30 phantom join code entry. The
            // promotion can throw either `PersonRepositoryError`
            // (preflight checks) or `FirestoreServiceError` (rules
            // rejection / network); both branches surface distinct
            // copy via `mapError`. Previously the catch dropped
            // everything past `.notCurrentPrimary` /
            // `.invalidPromotionTarget` into a single "generic"
            // string, which is the same collapse the convention is
            // meant to prevent.
            errorMessage = mapError(error)
        }
    }

    private func demoteToManagedClient() async {
        guard let targetID = person.id,
              let actorID = authService.currentPerson?.id else { return }
        isDemoting = true
        do {
            try await personRepo.demoteSupervisorToManagedClient(
                targetPersonID: targetID,
                actingSupervisorID: actorID
            )
            isDemoting = false
            showingDemoteSheet = false
            // Deliberately no `dismiss()`: the Person row is now a
            // managed_client, so the demote section disappears and the
            // managed<->device flip + medications sections appear on the
            // next body pass — the supervisor stays put and sees the result.
            onChanged()
        } catch {
            isDemoting = false
            showingDemoteSheet = false
            errorMessage = demoteErrorMessage(error)
        }
    }

    private func switchToTargetView() async {
        guard let targetID = person.id else { return }
        isSwitching = true
        do {
            try await authService.actAs(personID: targetID)
            isSwitching = false
            showingSwitchSheet = false
            // AuthGate re-routes to the acting person's view the moment
            // actingPersonID publishes; dismissing the detail sheet just
            // keeps the transition clean (no sheet hanging over TodayView).
            dismiss()
        } catch {
            isSwitching = false
            showingSwitchSheet = false
            // Distinct error codes per error-collapse convention — see
            // CLAUDE.md "Error-collapse convention"; the shared mapper keeps
            // one copy per ProfileSwitchError case, nothing collapsed.
            errorMessage = ProfileSwitchConfirmSheet.errorMessage(error)
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
        promoteToRole == Roles.deviceClient
            ? L("supervisor.person.promote.title")
            : L("supervisor.person.demote.title")
    }

    private var promoteAlertBody: String {
        promoteToRole == Roles.deviceClient
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
        // Distinct error codes per error-collapse convention — see
        // build_log April 30 phantom join code entry. Both the
        // domain repository error and the underlying Firestore error
        // are surfaced one-to-one so a rules rejection never reads
        // as "couldn't reach the server."
        if let err = error as? PersonRepositoryError {
            switch err {
            case .lastSupervisor:           return L("supervisor.person.error.lastsupervisor")
            case .permissionDenied:         return L("supervisor.person.error.notprimary")
            case .invalidPin:               return L("supervisor.person.error.invalidpin")
            case .invalidRoleTransition:    return L("supervisor.person.error.invalidrole")
            case .notCurrentPrimary:        return L("supervisor.promote.error.notprimary")
            case .invalidPromotionTarget:   return L("supervisor.promote.error.target")
            case .invalidDemotionTarget:    return L("people.demote.error.invalidtarget")
            case .notFound, .alreadyExists: return L("supervisor.person.error.generic")
            }
        }
        if let err = error as? FirestoreServiceError {
            switch err {
            case .permissionDenied: return L("supervisor.person.error.notprimary")
            case .offline:          return L("supervisor.person.error.offline")
            case .notFound:         return L("supervisor.person.error.notfound")
            case .unknown:          return L("supervisor.person.error.generic")
            }
        }
        return L("supervisor.person.error.generic")
    }

    /// Demote-specific error copy. The shared `mapError` returns the
    /// generic `supervisor.*` strings used by the other actions; this
    /// privilege-REMOVING flow gets its own `people.demote.*` set so each
    /// failure reads distinctly. Distinct error codes per the error-collapse
    /// convention — see build_log April 30 phantom join code entry: a rules
    /// rejection (`permissionDenied`) must never surface as "check your
    /// connection" (`offline`).
    private func demoteErrorMessage(_ error: Error) -> String {
        if let err = error as? PersonRepositoryError {
            switch err {
            case .notCurrentPrimary:     return L("people.demote.error.notcurrentprimary")
            case .invalidDemotionTarget: return L("people.demote.error.invalidtarget")
            case .permissionDenied:      return L("people.demote.error.permission")
            case .notFound:              return L("people.demote.error.notfound")
            default:                     return L("people.demote.error.unknown")
            }
        }
        if let err = error as? FirestoreServiceError {
            switch err {
            case .permissionDenied: return L("people.demote.error.permission")
            case .offline:          return L("people.demote.error.offline")
            case .notFound:         return L("people.demote.error.notfound")
            case .unknown:          return L("people.demote.error.unknown")
            }
        }
        return L("people.demote.error.unknown")
    }

    /// Whether the "Convert to managed family member" affordance should be
    /// shown. Pure and static so `PersonDetailViewTests` can pin every
    /// branch without hosting the view. Visible only when the viewer is the
    /// primary, the target is a `secondary_supervisor` (NOT the legacy
    /// `"supervisor"` alias, which reads as primary), the target isn't the
    /// viewer (no self-demotion), and the target isn't the current primary.
    static func shouldShowDemoteSection(
        targetRole: String?,
        targetPersonID: UUID?,
        actorPersonID: UUID?,
        primarySupervisorPersonID: UUID?,
        actorIsPrimary: Bool
    ) -> Bool {
        guard actorIsPrimary,
              targetRole == Roles.secondarySupervisor,
              let targetID = targetPersonID else { return false }
        if targetID == actorPersonID { return false }
        if targetID == primarySupervisorPersonID { return false }
        return true
    }

    /// Whether the "Switch to {name}'s view" affordance should be shown.
    /// Pure and static so `PersonDetailViewTests` can pin every branch
    /// without hosting the view. Visible only when the viewer is the primary
    /// (D2 — secondaries can't switch yet; Phase 2 widens), the target is a
    /// `managed_client` or `device_client` (D3 — never another supervisor),
    /// and the target isn't the viewer. Shared by the People-list context
    /// menu, so both entry points gate identically.
    static func shouldShowSwitchToView(
        targetRole: String?,
        targetPersonID: UUID?,
        actorPersonID: UUID?,
        actorIsPrimary: Bool
    ) -> Bool {
        guard actorIsPrimary,
              targetRole == Roles.managedClient || targetRole == Roles.deviceClient,
              let targetID = targetPersonID else { return false }
        return targetID != actorPersonID
    }
}
