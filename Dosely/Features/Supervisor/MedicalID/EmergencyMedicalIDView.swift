import SwiftUI

/// Read-only, large-format view of a person's emergency Medical ID —
/// the screen a caregiver or paramedic glances at. No edit, share, or
/// export controls live here; editing is `EditMedicalIDView` on a
/// supervisor's device.
///
/// Reads Core Data synchronously in `init` so it renders instantly and
/// works fully offline. There is no SyncCoordinator listener for medical
/// IDs (they hydrate only via the editor's `loadRemote` or a local save
/// mirror), so `task` fires one best-effort `loadRemote` to pull the
/// latest before a responder reads it — failure is silent and the cached
/// read already populated the screen.
///
/// Sections render only when they hold content: a skipped section forces
/// active verification, whereas "Allergies: none" reads as a positive
/// assertion a paramedic might trust against an incomplete record.
struct EmergencyMedicalIDView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let person: Person
    private let repository: MedicalIDRepository
    @State private var viewModel: EmergencyMedicalIDViewModel

    init(person: Person, repository: MedicalIDRepository = MedicalIDRepository()) {
        self.person = person
        self.repository = repository
        let row = person.id.flatMap { repository.fetchLocalSync(personID: $0) }
        _viewModel = State(initialValue: EmergencyMedicalIDViewModel(medicalID: row))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    headerBand
                    if viewModel.isEmptyState {
                        emptyStateCard
                    } else {
                        if viewModel.showBloodType { bloodTypeChip }
                        if viewModel.showAllergies {
                            listCard(titleKey: "emergency.medicalid.section.allergies",
                                     items: viewModel.allergies)
                        }
                        if viewModel.showConditions {
                            listCard(titleKey: "emergency.medicalid.section.conditions",
                                     items: viewModel.conditions)
                        }
                        if viewModel.showContacts { contactsCard }
                        if viewModel.showNotes { notesCard }
                    }
                }
                .padding(DSSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(Text("emergency.medicalid.viewer.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .task { await refreshFromRemote() }
        }
    }

    // MARK: - Header

    private var headerBand: some View {
        VStack(spacing: DSSpacing.sm) {
            avatar
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(person.name ?? "")
                .dsTitleLarge()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
            if let dobLine {
                Text(dobLine)
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DSSpacing.lg)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = person.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            ZStack {
                Color.dsBackground
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.dsTextSecondary)
            }
        }
    }

    // MARK: - Sections

    private var bloodTypeChip: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("emergency.medicalid.bloodtype.label")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
            Text(viewModel.bloodType)
                .dsTitleMedium()
                .foregroundColor(.dsDanger)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.sm)
                .background(Color.dsDanger.opacity(0.15))
                .cornerRadius(DSSpacing.rLg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(L("emergency.medicalid.bloodtype.label")) \(viewModel.bloodType)"))
    }

    private func listCard(titleKey: LocalizedStringKey, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(titleKey)
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
            ForEach(items, id: \.self) { item in
                Text(item)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private var contactsCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("emergency.medicalid.section.contacts")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
            ForEach(Array(viewModel.contacts.enumerated()), id: \.offset) { _, contact in
                contactButton(contact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private func contactButton(_ contact: FirestoreModels.FEmergencyContact) -> some View {
        Button {
            if let url = EmergencyMedicalIDViewModel.telURL(from: contact.phone) {
                openURL(url)
            }
        } label: {
            HStack(spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(contact.name)
                        .dsBodyLarge()
                        .fontWeight(.bold)
                        .foregroundColor(.dsTextPrimary)
                    Text(contact.phone)
                        .dsBodyLarge()
                        .foregroundColor(.dsPrimary)
                }
                Spacer()
                Image(systemName: "phone.fill")
                    .foregroundColor(.dsPrimary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("emergency.medicalid.contact.call.a11yLabel",
                                    contact.name as NSString,
                                    spokenPhone(contact.phone) as NSString)))
        .accessibilityHint(Text("emergency.medicalid.contact.call.a11yHint"))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("emergency.medicalid.section.notes")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
            Text(viewModel.notes)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private var emptyStateCard: some View {
        VStack(spacing: DSSpacing.sm) {
            Text("emergency.medicalid.empty.title")
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
            Text("emergency.medicalid.empty.subtitle")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DSSpacing.xl)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    // MARK: - Derived copy / refresh

    private var dobLine: String? {
        guard let dob = viewModel.dateOfBirth else { return nil }
        let dateStr = LocalizedFormatters.dateFormatter(format: "MMMM d, yyyy").string(from: dob)
        guard let age = viewModel.age() else { return dateStr }
        return L("emergency.medicalid.dob", dateStr as NSString, age)
    }

    private func spokenPhone(_ phone: String) -> String {
        phone.filter(\.isNumber).map(String.init).joined(separator: " ")
    }

    private func refreshFromRemote() async {
        guard let pid = person.id, let cid = person.careCircle?.id else { return }
        _ = try? await repository.loadRemote(personID: pid, circleID: cid)
        viewModel = EmergencyMedicalIDViewModel(medicalID: repository.fetchLocalSync(personID: pid))
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private enum EmergencyMedicalIDPreviewFactory {
    /// An in-memory stack seeded with one fully-populated Medical ID, returning
    /// the Person + repository the viewer reads in `init`. Mirrors the fixture
    /// in EmergencyMedicalIDViewTests so the preview walks the real
    /// init → fetchLocalSync → decode path — the same one a paramedic hits.
    static func populated() -> (Person, MedicalIDRepository) {
        let stack = CoreDataStack(inMemory: true)
        let repo = MedicalIDRepository(stack: stack, firestore: FirestoreService())
        let ctx = stack.viewContext
        let id = UUID()
        let person = Person(context: ctx)
        person.id = id
        person.name = "Margaret Chen"
        person.role = Roles.managedClient
        let record = FirestoreModels.FMedicalID(
            id: id.uuidString,
            personID: id.uuidString,
            dateOfBirth: nil,
            bloodType: "O+",
            allergies: ["Penicillin", "Sulfa drugs"],
            conditions: ["Type 2 diabetes", "Atrial fibrillation"],
            emergencyContacts: [
                FirestoreModels.FEmergencyContact(
                    name: "Aunt Bibi", relationship: "Daughter", phone: "555-0101"
                )
            ],
            notes: "Hard of hearing on the left side. Wears a hearing aid.",
            updatedAt: Date()
        )
        _ = record.upsert(in: ctx)
        try? ctx.save()
        return (person, repo)
    }
}

#Preview("Emergency Medical ID · light") {
    let (person, repo) = EmergencyMedicalIDPreviewFactory.populated()
    return EmergencyMedicalIDView(person: person, repository: repo)
        .preferredColorScheme(.light)
}

#Preview("Emergency Medical ID · dark") {
    let (person, repo) = EmergencyMedicalIDPreviewFactory.populated()
    return EmergencyMedicalIDView(person: person, repository: repo)
        .preferredColorScheme(.dark)
}
#endif
