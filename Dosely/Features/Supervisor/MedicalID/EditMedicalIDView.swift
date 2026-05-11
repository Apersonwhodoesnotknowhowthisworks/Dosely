import SwiftUI

/// Editor for the per-person Medical ID. Both primary and secondary
/// supervisors can edit — intentionally egalitarian. Save runs the
/// Firestore-first pattern in `MedicalIDRepository.save`: remote
/// commit happens first, and only on success does the local mirror
/// update. A failure leaves the prior state intact and surfaces an
/// inline error.
///
/// Two entry points:
///   1. Dashboard Quick Actions — if no person is preselected the
///      view shows an in-flow target picker (same pattern as
///      `AddMedicationFlow`).
///   2. PersonDetailView's Medical ID section — person is injected
///      via the `supervisorTargetPersonID` environment value.
struct EditMedicalIDView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.supervisorTargetPersonID) private var envTargetPersonID: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var pickedTargetPersonID: UUID?
    @State private var dateOfBirth: Date = Date()
    @State private var includesDateOfBirth: Bool = false
    @State private var bloodType: String = ""
    @State private var allergies: [String] = []
    @State private var conditions: [String] = []
    @State private var emergencyContacts: [FirestoreModels.FEmergencyContact] = []
    @State private var notes: String = ""
    @State private var isLoaded: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveErrorVisible = false

    private let repository: MedicalIDRepository

    init(repository: MedicalIDRepository = MedicalIDRepository()) {
        self.repository = repository
    }

    private var resolvedTargetPersonID: UUID? {
        envTargetPersonID ?? pickedTargetPersonID
    }

    /// Pure decision used by `body`. Extracted as a static helper so
    /// the regression smoke test can verify the picker-vs-form
    /// branching without running a full SwiftUI render.
    static func shouldShowTargetPicker(
        envTargetPersonID: UUID?,
        pickedTargetPersonID: UUID?
    ) -> Bool {
        envTargetPersonID == nil && pickedTargetPersonID == nil
    }

    var body: some View {
        Group {
            if Self.shouldShowTargetPicker(
                envTargetPersonID: envTargetPersonID,
                pickedTargetPersonID: pickedTargetPersonID
            ) {
                AddMedicationTargetPicker(
                    onPick: { pickedTargetPersonID = $0 },
                    onCancel: { dismiss() },
                    titleKey: "supervisor.medicalid.picker.title"
                )
            } else {
                editorForm
            }
        }
    }

    // MARK: - Form

    private var editorForm: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    basicSection
                    allergiesSection
                    conditionsSection
                    emergencyContactsSection
                    notesSection
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(Text("supervisor.medicalid.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.save")) {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .alert(L("supervisor.medicalid.save.error.title"),
                   isPresented: $saveErrorVisible) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text("supervisor.medicalid.save.error.body")
            }
            .task(id: resolvedTargetPersonID) {
                await loadExisting()
            }
        }
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("supervisor.medicalid.basic.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("supervisor.medicalid.dob")
                    .dsCaption()
                    .foregroundColor(.dsTextSecondary)
                HStack {
                    DatePicker(
                        "",
                        selection: $dateOfBirth,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .disabled(!includesDateOfBirth)
                    Spacer()
                    Toggle("", isOn: $includesDateOfBirth)
                        .labelsHidden()
                        .accessibilityLabel(Text("supervisor.medicalid.dob"))
                }
            }

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("supervisor.medicalid.bloodtype")
                    .dsCaption()
                    .foregroundColor(.dsTextSecondary)
                TextField(L("supervisor.medicalid.bloodtype.placeholder"), text: $bloodType)
                    .dsBodyLarge()
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
            }
        }
    }

    private var allergiesSection: some View {
        editableListSection(
            title: "supervisor.medicalid.allergies.title",
            placeholder: "supervisor.medicalid.allergies.placeholder",
            addLabel: "supervisor.medicalid.allergies.add",
            items: $allergies
        )
    }

    private var conditionsSection: some View {
        editableListSection(
            title: "supervisor.medicalid.conditions.title",
            placeholder: "supervisor.medicalid.conditions.placeholder",
            addLabel: "supervisor.medicalid.conditions.add",
            items: $conditions
        )
    }

    private func editableListSection(title: LocalizedStringKey,
                                     placeholder: String,
                                     addLabel: LocalizedStringKey,
                                     items: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(title)
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
            ForEach(items.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: DSSpacing.sm) {
                    TextField(L(placeholder), text: Binding(
                        get: { items.wrappedValue[index] },
                        set: { items.wrappedValue[index] = $0 }
                    ))
                    .dsBodyLarge()
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
                    Button(action: {
                        items.wrappedValue.remove(at: index)
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.dsDanger)
                            .frame(width: DSSpacing.minTapTarget,
                                   height: DSSpacing.minTapTarget)
                    }
                    .accessibilityLabel(Text("supervisor.medicalid.remove"))
                }
            }
            Button(action: { items.wrappedValue.append("") }) {
                Label(addLabel, systemImage: "plus.circle.fill")
                    .dsBodyRegular()
                    .foregroundColor(.dsPrimary)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
            }
        }
    }

    private var emergencyContactsSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("supervisor.medicalid.contacts.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
            ForEach(emergencyContacts.indices, id: \.self) { index in
                emergencyContactRow(at: index)
            }
            Button(action: {
                emergencyContacts.append(
                    FirestoreModels.FEmergencyContact(name: "", relationship: "", phone: "")
                )
            }) {
                Label("supervisor.medicalid.contacts.add", systemImage: "plus.circle.fill")
                    .dsBodyRegular()
                    .foregroundColor(.dsPrimary)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
            }
        }
    }

    private func emergencyContactRow(at index: Int) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                Text("supervisor.medicalid.contacts.row")
                    .dsCaption()
                    .foregroundColor(.dsTextSecondary)
                Spacer()
                Button(action: {
                    emergencyContacts.remove(at: index)
                }) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.dsDanger)
                        .frame(width: DSSpacing.minTapTarget,
                               height: DSSpacing.minTapTarget)
                }
                .accessibilityLabel(Text("supervisor.medicalid.remove"))
            }
            TextField(L("supervisor.medicalid.contacts.name"),
                      text: Binding(
                        get: { emergencyContacts[index].name },
                        set: { emergencyContacts[index].name = $0 }
                      ))
            .dsBodyLarge()
            .padding(DSSpacing.md)
            .frame(minHeight: DSSpacing.minTapTarget)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
            TextField(L("supervisor.medicalid.contacts.relationship"),
                      text: Binding(
                        get: { emergencyContacts[index].relationship },
                        set: { emergencyContacts[index].relationship = $0 }
                      ))
            .dsBodyLarge()
            .padding(DSSpacing.md)
            .frame(minHeight: DSSpacing.minTapTarget)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
            TextField(L("supervisor.medicalid.contacts.phone"),
                      text: Binding(
                        get: { emergencyContacts[index].phone },
                        set: { emergencyContacts[index].phone = $0 }
                      ))
            .dsBodyLarge()
            .padding(DSSpacing.md)
            .frame(minHeight: DSSpacing.minTapTarget)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
            .keyboardType(.phonePad)
        }
        .padding(DSSpacing.md)
        .background(Color.dsBackground)
        .cornerRadius(DSSpacing.rMd)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("supervisor.medicalid.notes.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
            Text("supervisor.medicalid.notes.subtitle")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $notes)
                .dsBodyRegular()
                .frame(minHeight: 120)
                .padding(DSSpacing.sm)
                .background(Color.dsSurface)
                .cornerRadius(DSSpacing.rMd)
        }
    }

    // MARK: - Load / save

    private func loadExisting() async {
        guard let personID = resolvedTargetPersonID,
              let circleID = authService.currentPerson?.careCircle?.id else {
            isLoaded = true
            return
        }
        let remote: MedicalID? = await {
            // Try remote first so what the editor displays matches
            // what other supervisors see. Fall back to the local
            // mirror if offline / permission-denied — better stale
            // than empty.
            if let row = try? await repository.loadRemote(
                personID: personID, circleID: circleID
            ) {
                return row
            }
            return await repository.fetchLocal(personID: personID)
        }()
        await MainActor.run {
            apply(row: remote)
            isLoaded = true
        }
    }

    private func apply(row: MedicalID?) {
        guard let row else {
            includesDateOfBirth = false
            bloodType = ""
            allergies = []
            conditions = []
            emergencyContacts = []
            notes = ""
            return
        }
        if let dob = row.dateOfBirth {
            includesDateOfBirth = true
            dateOfBirth = dob
        } else {
            includesDateOfBirth = false
        }
        bloodType = row.bloodType ?? ""
        allergies = FirestoreModels.FMedicalID.decodeStringList(row.allergiesJSON)
        conditions = FirestoreModels.FMedicalID.decodeStringList(row.conditionsJSON)
        emergencyContacts = FirestoreModels.FMedicalID.decodeContacts(row.emergencyContactsJSON)
        notes = row.notes ?? ""
    }

    private func save() async {
        guard let personID = resolvedTargetPersonID,
              let circleID = authService.currentPerson?.careCircle?.id else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.save(
                personID: personID,
                circleID: circleID,
                dateOfBirth: includesDateOfBirth ? dateOfBirth : nil,
                bloodType: bloodType,
                allergies: allergies,
                conditions: conditions,
                emergencyContacts: emergencyContacts,
                notes: notes
            )
            await MainActor.run { dismiss() }
        } catch {
            await MainActor.run { saveErrorVisible = true }
        }
    }
}
