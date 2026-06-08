import OSLog
import SwiftUI

struct PeopleManagementView: View {
    @EnvironmentObject var authService: AuthService
    @State private var people: [Person] = []
    @State private var isLoaded = false
    @State private var showingAdd = false
    @State private var detailPerson: Person?
    @State private var refreshErrorMessage: String?

    let personRepo: PersonRepository
    let careCircleRepo: CareCircleRepository
    let medicationRepo: MedicationRepository

    init(personRepo: PersonRepository,
         careCircleRepo: CareCircleRepository,
         medicationRepo: MedicationRepository = MedicationRepository()) {
        self.personRepo = personRepo
        self.careCircleRepo = careCircleRepo
        self.medicationRepo = medicationRepo
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    if !isLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if people.isEmpty {
                        emptyState
                    } else {
                        peopleList
                    }

                    if isLoaded, let circleID = authService.currentPerson?.careCircle?.id {
                        CircleSettingsSection(
                            careCircleID: circleID,
                            careCircleRepo: careCircleRepo
                        )
                        .id(circleID)
                    }
                }
                .padding(DSSpacing.lg)
            }
            .refreshable {
                await PullToRefresh.perform(messageBinding: $refreshErrorMessage)
                await reload()
            }
            .pullToRefreshBanner(message: $refreshErrorMessage)
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(Text("supervisor.people.title"))
            .toolbar {
                if isPrimary {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { showingAdd = true }) {
                            Image(systemName: "plus")
                                .font(.title2.weight(.semibold))
                                .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                        }
                        .accessibilityLabel(Text("supervisor.people.add"))
                    }
                }
            }
        }
        .task(id: authService.currentPerson?.id) {
            await reload()
        }
        .sheet(isPresented: $showingAdd) {
            AddPersonFlow(personRepo: personRepo,
                          careCircleRepo: careCircleRepo) {
                Task { await reload() }
            }
            .environmentObject(authService)
        }
        .sheet(item: $detailPerson) { person in
            PersonDetailView(person: person,
                             personRepo: personRepo,
                             medicationRepo: medicationRepo) {
                Task { await reload() }
            }
            .environmentObject(authService)
        }
    }

    // MARK: - Sections

    private var peopleList: some View {
        VStack(spacing: DSSpacing.sm) {
            ForEach(people, id: \.id) { person in
                Button(action: { detailPerson = person }) {
                    PersonRow(person: person,
                              isCurrentSupervisor: person.id == authService.currentPerson?.id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(person.name ?? "") — \(roleLabel(person.role))"))
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: DSSpacing.md) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 48))
                .foregroundColor(.dsPrimary)
                .accessibilityHidden(true)
            Text("supervisor.people.empty.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
            Text("supervisor.people.empty.body")
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(DSSpacing.xl)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    // MARK: - Data

    private func reload() async {
        guard let circleID = authService.currentPerson?.careCircle?.id else {
            isLoaded = true
            return
        }
        let fetched = await personRepo.fetchAllPeople(in: circleID)
        // Sort: primary supervisor first, then secondary supervisors,
        // then clients alphabetically.
        people = fetched.sorted { lhs, rhs in
            let lhsTier = Self.roleTier(lhs.role)
            let rhsTier = Self.roleTier(rhs.role)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            return (lhs.name ?? "") < (rhs.name ?? "")
        }
        isLoaded = true
    }

    private static func roleTier(_ role: String?) -> Int {
        switch role {
        case Roles.primarySupervisor, Roles.legacySupervisor: return 0
        case Roles.secondarySupervisor:                        return 1
        default:                                               return 2
        }
    }

    private var isPrimary: Bool {
        guard let person = authService.currentPerson,
              let circle = person.careCircle,
              let me = person.id else { return false }
        if let primaryID = circle.primarySupervisorPersonID {
            return primaryID == me
        }
        return Roles.isPrimarySupervisor(person.role)
    }

    private func roleLabel(_ role: String?) -> String {
        switch role {
        case Roles.primarySupervisor, Roles.legacySupervisor:
            return L("supervisor.role.primary")
        case Roles.secondarySupervisor:
            return L("supervisor.role.secondary")
        case Roles.deviceClient:
            return L("supervisor.role.deviceclient")
        case Roles.managedClient:
            return L("supervisor.role.managedclient")
        default:
            return ""
        }
    }
}

// MARK: - Row

struct PersonRow: View {
    let person: Person
    let isCurrentSupervisor: Bool

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            avatar
                .frame(width: 48, height: 48)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.xs) {
                    Text(person.name ?? "")
                        .dsBodyLarge()
                        .foregroundColor(.dsTextPrimary)
                    if isCurrentSupervisor {
                        Text("supervisor.people.you")
                            .dsCaption()
                            .foregroundColor(.dsTextSecondary)
                    }
                }
                Text(roleBadge)
                    .dsCaption()
                    .foregroundColor(badgeColor)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15))
                    .cornerRadius(DSSpacing.rSm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .foregroundColor(.dsTextSecondary)
                .accessibilityHidden(true)
        }
        .padding(DSSpacing.md)
        .frame(minHeight: DSSpacing.minTapTarget)
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
                    .font(.system(size: 28))
                    .foregroundColor(.dsTextSecondary)
            }
        }
    }

    private var roleBadge: String {
        switch person.role {
        case Roles.primarySupervisor, Roles.legacySupervisor:
            return L("supervisor.role.primary")
        case Roles.secondarySupervisor:
            return L("supervisor.role.secondary")
        case Roles.deviceClient:
            return L("supervisor.role.deviceclient")
        case Roles.managedClient:
            return L("supervisor.role.managedclient")
        default:
            return ""
        }
    }

    private var badgeColor: Color {
        switch person.role {
        case Roles.primarySupervisor, Roles.legacySupervisor:
            return .dsPrimary
        case Roles.secondarySupervisor:
            return .dsTextSecondary
        case Roles.deviceClient:
            return .dsSuccess
        case Roles.managedClient:
            return .dsWarning
        default:
            return .dsTextSecondary
        }
    }
}

// MARK: - Circle settings (rename, regenerate join code)

struct CircleSettingsSection: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var viewModel: CircleSettingsViewModel
    @State private var renameText: String = ""
    @State private var showingRenameAlert = false
    @State private var showingRegenAlert = false
    @State private var regenerateErrorMessage: String?
    @State private var isRegenerating = false

    let careCircleRepo: CareCircleRepository

    private static let logger = Logger(subsystem: "com.medication.dosely", category: "carecircle")

    init(careCircleID: UUID, careCircleRepo: CareCircleRepository) {
        self.careCircleRepo = careCircleRepo
        _viewModel = StateObject(wrappedValue: CircleSettingsViewModel(careCircleID: careCircleID))
    }

    private var isPrimary: Bool {
        guard let person = authService.currentPerson,
              let circle = person.careCircle,
              let me = person.id else { return false }
        if let primaryID = circle.primarySupervisorPersonID {
            return primaryID == me
        }
        return Roles.isPrimarySupervisor(person.role)
    }

    /// The join code to display: the real code when present, otherwise a clean
    /// loading state — never a bare placeholder character. Pure + static so
    /// `PeopleManagementViewTests` can pin it.
    static func joinCodeDisplayValue(_ code: String?, loadingText: String) -> String {
        guard let code, !code.isEmpty else { return loadingText }
        return code
    }

    /// The circle name to display: the real name, or a localized placeholder
    /// when it's blank (a primary who hit Create without typing a name). Pure +
    /// static so the tests can pin it; never renders an empty Text.
    static func circleNameDisplayValue(_ name: String, placeholder: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? placeholder : name
    }

    private var joinCodeDisplay: String {
        Self.joinCodeDisplayValue(viewModel.joinCode, loadingText: L("supervisor.circle.joincode.loading"))
    }

    private var circleNameDisplay: String {
        Self.circleNameDisplayValue(viewModel.circleName, placeholder: L("supervisor.circle.name.placeholder"))
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { regenerateErrorMessage != nil },
                set: { if !$0 { regenerateErrorMessage = nil } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("supervisor.circle.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)

            if isPrimary {
                row(title: L("supervisor.circle.name"),
                    value: circleNameDisplay,
                    action: { renameText = viewModel.circleName; showingRenameAlert = true })
                joinCodeRow(showRegenerate: true)
            } else {
                readOnlyRow(title: L("supervisor.circle.name"), value: circleNameDisplay)
                joinCodeRow(showRegenerate: false)
            }
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
        .alert(L("supervisor.circle.rename.title"),
               isPresented: $showingRenameAlert) {
            TextField(L("supervisor.circle.name"), text: $renameText)
            Button(L("common.save")) {
                Task { await rename(to: renameText) }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
        .alert(L("supervisor.circle.regenerate.title"),
               isPresented: $showingRegenAlert) {
            Button(L("supervisor.circle.regenerate"), role: .destructive) {
                Task { await regenerate() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("supervisor.circle.regenerate.body", (viewModel.joinCode ?? "") as NSString))
        }
        .alert(L("settings.family.regenerate.error.title"),
               isPresented: errorBinding) {
            Button(L("common.ok"), role: .cancel) { regenerateErrorMessage = nil }
        } message: {
            Text(regenerateErrorMessage ?? "")
        }
    }

    private func row(title: String,
                     value: String,
                     actionLabel: String? = nil,
                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title).dsCaption().foregroundColor(.dsTextSecondary)
                Text(value)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                Text(actionLabel ?? L("common.edit"))
                    .dsBodyRegular()
                    .foregroundColor(.dsPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .frame(minHeight: DSSpacing.minTapTarget)
            }
            .accessibilityLabel(Text("\(actionLabel ?? L("common.edit")) — \(title)"))
        }
        .padding(.vertical, DSSpacing.xs)
    }

    /// Join code row: the value is visually prominent (`dsTitleMedium`, since a
    /// primary reads it aloud to share access), and the regenerate control
    /// swaps to a spinner and disables itself while the request is in flight.
    @ViewBuilder
    private func joinCodeRow(showRegenerate: Bool) -> some View {
        HStack(alignment: .center, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("supervisor.circle.joincode").dsCaption().foregroundColor(.dsTextSecondary)
                Text(joinCodeDisplay)
                    .dsTitleMedium()
                    .foregroundColor(.dsTextPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showRegenerate {
                Button(action: { showingRegenAlert = true }) {
                    Group {
                        if isRegenerating {
                            ProgressView()
                        } else {
                            Text("supervisor.circle.regenerate")
                                .dsBodyRegular()
                                .foregroundColor(.dsPrimary)
                        }
                    }
                    .padding(.horizontal, DSSpacing.sm)
                    .frame(minHeight: DSSpacing.minTapTarget)
                }
                .disabled(isRegenerating)
                .accessibilityLabel(Text("\(L("supervisor.circle.regenerate")) — \(L("supervisor.circle.joincode"))"))
            }
        }
        .padding(.vertical, DSSpacing.xs)
    }

    private func readOnlyRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(title).dsCaption().foregroundColor(.dsTextSecondary)
            Text(value)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DSSpacing.xs)
    }

    private func rename(to newName: String) async {
        guard let circleID = authService.currentPerson?.careCircle?.id,
              let actorID = authService.currentPerson?.id else { return }
        do {
            try await careCircleRepo.renameCircle(careCircleID: circleID,
                                                  newName: newName,
                                                  actorPersonID: actorID)
            // The new name reaches the card via the view model's Core Data
            // observer (renameCircle mirrors it to the viewContext).
        } catch {
            // Permission / blank name — silent on this surface; the
            // primary-only affordances are hidden for secondaries.
        }
    }

    private func regenerate() async {
        guard let circleID = authService.currentPerson?.careCircle?.id,
              let actorID = authService.currentPerson?.id else { return }
        isRegenerating = true
        do {
            _ = try await careCircleRepo.regenerateJoinCode(
                careCircleID: circleID, actorPersonID: actorID
            )
            // The new code reaches the card via the view model's Core Data
            // observer (regenerateJoinCode mirrors it to the viewContext).
            await MainActor.run { isRegenerating = false }
        } catch let error as CareCircleEditError {
            // Distinct error codes per error-collapse convention — see
            // build_log April 30 phantom join code entry. The repo preserves
            // the four cases; the UI must too. A rules rejection
            // (permissionDenied) must never read as "check your connection".
            let message: String
            switch error {
            case .permissionDenied:
                message = L("supervisor.circle.regenerate.error.permission")
            case .offline:
                message = L("supervisor.circle.regenerate.error.offline")
            case .notFound:
                message = L("supervisor.circle.regenerate.error.notfound")
            case .invalidName:
                message = L("supervisor.circle.regenerate.error.unknown")
            case .unknown(let detail):
                Self.logger.error("regenerateJoinCode failed: \(detail, privacy: .public)")
                message = L("supervisor.circle.regenerate.error.unknown")
            }
            await MainActor.run {
                regenerateErrorMessage = message
                isRegenerating = false
            }
        } catch {
            await MainActor.run {
                regenerateErrorMessage = L("supervisor.circle.regenerate.error.unknown")
                isRegenerating = false
            }
        }
    }
}
