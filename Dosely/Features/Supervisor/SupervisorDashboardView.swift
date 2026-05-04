import SwiftUI

/// Three-tab supervisor home: Today (this view), History (week grid for
/// the active person), People (manage care circle).
struct SupervisorDashboardView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var viewModel: SupervisorDashboardViewModel
    @State private var activePersonID: UUID? = nil
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var showingMedicalIDPlaceholder = false
    @State private var detailDose: TodayDose?
    @State private var historyPersonIDOverride: UUID?
    @State private var pendingAddTargetPersonID: UUID?
    @State private var promptAddTargetPicker = false
    @State private var todayRefreshError: String?

    private let medicationRepo: MedicationRepository
    private let personRepo: PersonRepository
    private let careCircleRepo: CareCircleRepository

    init(medicationRepo: MedicationRepository = MedicationRepository(),
         personRepo: PersonRepository = PersonRepository(),
         careCircleRepo: CareCircleRepository = CareCircleRepository()) {
        self.medicationRepo = medicationRepo
        self.personRepo = personRepo
        self.careCircleRepo = careCircleRepo
        _viewModel = StateObject(wrappedValue: SupervisorDashboardViewModel(
            medicationRepo: medicationRepo,
            personRepo: personRepo
        ))
    }

    var body: some View {
        TabView {
            todayTab
                .tabItem { Label("today.title", systemImage: "house.fill") }
            historyTab
                .tabItem { Label("history.title", systemImage: "calendar") }
            peopleTab
                .tabItem { Label("supervisor.tab.people", systemImage: "person.2.fill") }
        }
        .tint(.dsPrimary)
    }

    // MARK: - Role gates

    /// True iff `authService.currentPerson` is the primary supervisor of
    /// their care circle. Drives the read-only-mode hide rules across
    /// the dashboard.
    private var isPrimary: Bool {
        guard let person = authService.currentPerson,
              let circle = person.careCircle,
              let me = person.id else { return false }
        if let primaryID = circle.primarySupervisorPersonID {
            return primaryID == me
        }
        // Pre-`PrimaryRoleMigration` data — legacy `supervisor` is primary.
        return Roles.isPrimarySupervisor(person.role)
    }

    /// Display name of the current primary supervisor (for the
    /// "Only X can change this" inline notice). Looks them up among
    /// the people in the local CareCircle. Returns nil for the
    /// pre-migration race where the field hasn't propagated yet.
    private var primaryName: String? {
        guard let circle = authService.currentPerson?.careCircle,
              let primaryID = circle.primarySupervisorPersonID,
              let people = circle.people as? Set<Person> else { return nil }
        return people.first(where: { $0.id == primaryID })?.name
    }

    // MARK: - Today tab

    private var todayTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    PersonSelector(clients: viewModel.clients,
                                   activePersonID: $activePersonID)
                        .padding(.bottom, DSSpacing.xs)

                    Text(LocalizedFormatters.fullDateFormatter.string(from: Date()))
                        .dsBodyLarge()
                        .foregroundColor(.dsTextSecondary)
                        .padding(.horizontal, DSSpacing.lg)

                    contentBody
                        .padding(.horizontal, DSSpacing.lg)
                }
                .padding(.vertical, DSSpacing.md)
            }
            .refreshable {
                await PullToRefresh.perform(messageBinding: $todayRefreshError)
                await reload()
            }
            .pullToRefreshBanner(message: $todayRefreshError)
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle("today.title")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "person.crop.circle")
                            .font(.title2.weight(.semibold))
                            .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                    }
                    .accessibilityLabel(Text("today.account"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    RoleBadge(isPrimary: isPrimary, primaryName: primaryName)
                }
            }
        }
        .task(id: refreshKey) {
            await reload()
        }
        // Foreground re-runs `reload`, which fires the missed-dose
        // detector and the weekly summary generator alongside the
        // dose refresh. Without push, foreground is the most
        // reliable signal that the supervisor wants fresh state.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showingAdd) {
            // Sheet content must NEVER be empty — wrapping the body in
            // `if let target = pendingAddTargetPersonID` previously
            // produced a blank white sheet whenever the state hadn't
            // settled by render time. The flow now always renders;
            // `supervisorTargetPersonID` is optional and falls back to
            // an in-flow person picker when nil.
            AddMedicationFlow(repository: medicationRepo) {
                Task { await reload() }
            }
            .environmentObject(authService)
            .environment(\.supervisorTargetPersonID, pendingAddTargetPersonID)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
        }
        .sheet(item: $detailDose) { dose in
            MedicationDetailView(
                name: dose.medication.name ?? "",
                dose: dose.medication.dose ?? "",
                pillPhotoData: dose.medication.pillPhotoData
            )
        }
        .alert(L("supervisor.medicalid.placeholder.title"),
               isPresented: $showingMedicalIDPlaceholder) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text("supervisor.medicalid.placeholder.body")
        }
        .confirmationDialog(L("supervisor.addmed.picker.title"),
                            isPresented: $promptAddTargetPicker,
                            titleVisibility: .visible) {
            ForEach(viewModel.clients, id: \.id) { person in
                Button((person.name ?? "")) {
                    pendingAddTargetPersonID = person.id
                    showingAdd = true
                }
            }
            if let supervisorID = authService.currentPerson?.id {
                Button(L("supervisor.addmed.picker.self")) {
                    pendingAddTargetPersonID = supervisorID
                    showingAdd = true
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if !viewModel.isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if viewModel.clients.isEmpty {
            emptyCircleState
        } else {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                SupervisorScheduleSection(
                    doses: viewModel.doses,
                    personName: activePerson?.name,
                    people: viewModel.clients,
                    onTake: { dose in Task { await markTaken(dose) } },
                    onSkip: { dose in Task { await skip(dose) } },
                    onLearnMore: { dose in detailDose = dose },
                    showActions: isPrimary
                )

                if let adherence = viewModel.adherence {
                    AdherenceSummaryCard(adherence: adherence) {
                        historyPersonIDOverride = adherence.id
                    }
                }

                AlertsCard(alerts: viewModel.alerts) { alert in
                    Task { await acknowledge(alert) }
                }

                if isPrimary {
                    if activePersonID != nil {
                        QuickActionsCard(
                            onAddMedication: {
                                pendingAddTargetPersonID = activePersonID
                                showingAdd = true
                            },
                            onEditMedicalID: { showingMedicalIDPlaceholder = true },
                            onSettings: { showingSettings = true }
                        )
                    } else {
                        QuickActionsCard(
                            onAddMedication: { promptAddTargetPicker = true },
                            onEditMedicalID: { showingMedicalIDPlaceholder = true },
                            onSettings: { showingSettings = true }
                        )
                    }
                } else {
                    SecondaryReadOnlyNotice(primaryName: primaryName)
                }
            }
        }
    }

    private var emptyCircleState: some View {
        VStack(alignment: .center, spacing: DSSpacing.md) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 48))
                .foregroundColor(.dsPrimary)
                .accessibilityHidden(true)
            Text("supervisor.empty.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
            Text("supervisor.empty.body")
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

    // MARK: - History tab

    private var historyTab: some View {
        HistoryView(repository: medicationRepo,
                    personIDOverride: historyPersonIDOverride ?? activePersonID)
    }

    // MARK: - People tab

    private var peopleTab: some View {
        PeopleManagementView(personRepo: personRepo,
                             careCircleRepo: careCircleRepo,
                             medicationRepo: medicationRepo)
    }

    // MARK: - Helpers

    private var activePerson: Person? {
        guard let activePersonID else { return nil }
        return viewModel.clients.first(where: { $0.id == activePersonID })
    }

    /// Combined task-id: re-run the load when the supervisor (sign-in
    /// state) or the active person changes.
    private var refreshKey: String {
        let supervisor = authService.currentPerson?.id?.uuidString ?? "no-supervisor"
        let active = activePersonID?.uuidString ?? "all"
        return "\(supervisor)|\(active)"
    }

    private func reload() async {
        guard
            let supervisor = authService.currentPerson,
            let supervisorID = supervisor.id,
            let circleID = supervisor.careCircle?.id
        else { return }
        await viewModel.load(circleID: circleID,
                             supervisorID: supervisorID,
                             activePersonID: activePersonID)
    }

    private func markTaken(_ dose: TodayDose) async {
        guard
            let supervisor = authService.currentPerson,
            let supervisorID = supervisor.id,
            let circleID = supervisor.careCircle?.id
        else { return }
        await viewModel.markTaken(dose,
                                  supervisorID: supervisorID,
                                  activePersonID: activePersonID,
                                  circleID: circleID)
    }

    private func skip(_ dose: TodayDose) async {
        guard
            let supervisor = authService.currentPerson,
            let supervisorID = supervisor.id,
            let circleID = supervisor.careCircle?.id
        else { return }
        await viewModel.skip(dose,
                             supervisorID: supervisorID,
                             activePersonID: activePersonID,
                             circleID: circleID)
    }

    private func acknowledge(_ alert: Alert) async {
        guard
            let supervisor = authService.currentPerson,
            let supervisorID = supervisor.id,
            let circleID = supervisor.careCircle?.id,
            let firebaseUID = authService.currentUser?.uid
        else { return }
        await viewModel.acknowledge(
            alert,
            supervisorID: supervisorID,
            supervisorFirebaseUID: firebaseUID,
            supervisorName: supervisor.name,
            activePersonID: activePersonID,
            circleID: circleID
        )
    }
}

// MARK: - Role badge (top-right of dashboard)

/// Compact pill in the navbar showing whether the current supervisor is
/// primary or secondary. Doubles as an accessibility hint about who
/// holds write authority in the circle.
private struct RoleBadge: View {
    let isPrimary: Bool
    let primaryName: String?

    var body: some View {
        Text(isPrimary ? L("supervisor.badge.primary") : L("supervisor.badge.viewonly"))
            .dsCaption()
            .foregroundColor(isPrimary ? .white : .dsTextSecondary)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 4)
            .background(isPrimary ? Color.dsPrimary : Color.dsBackground)
            .overlay(
                RoundedRectangle(cornerRadius: DSSpacing.rSm)
                    .stroke(isPrimary ? Color.clear : Color.dsTextSecondary.opacity(0.4), lineWidth: 1)
            )
            .cornerRadius(DSSpacing.rSm)
            .accessibilityLabel(Text(a11yLabel))
    }

    private var a11yLabel: String {
        if isPrimary {
            return L("supervisor.badge.primary.a11y")
        }
        if let name = primaryName {
            return L("supervisor.badge.viewonly.a11y", name as NSString)
        }
        return L("supervisor.badge.viewonly")
    }
}

// MARK: - Read-only notice for secondaries

/// Inline card explaining that write actions are disabled for the
/// current user, with a pointer at who can perform them.
private struct SecondaryReadOnlyNotice: View {
    let primaryName: String?

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Image(systemName: "lock.fill")
                .foregroundColor(.dsTextSecondary)
                .accessibilityHidden(true)
            Text(message)
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

    private var message: String {
        if let name = primaryName {
            return L("supervisor.readonly.notice", name as NSString)
        }
        return L("supervisor.readonly.notice.unknown")
    }
}

// MARK: - Environment for AddMedicationFlow's target person

private struct SupervisorTargetPersonIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// When the supervisor opens AddMedicationFlow on behalf of a client,
    /// this carries the target Person.id so the flow saves to the right
    /// patient. AddMedicationFlow falls back to the supervisor's own id
    /// when the value is nil (the legacy single-person path).
    var supervisorTargetPersonID: UUID? {
        get { self[SupervisorTargetPersonIDKey.self] }
        set { self[SupervisorTargetPersonIDKey.self] = newValue }
    }
}

#if DEBUG
@MainActor
private enum SupervisorPreviewFactory {
    static func emptyStack() -> CoreDataStack { CoreDataStack(inMemory: true) }
}

#Preview("Dashboard · empty circle") {
    SupervisorDashboardView(
        medicationRepo: MedicationRepository(stack: SupervisorPreviewFactory.emptyStack()),
        personRepo: PersonRepository(stack: SupervisorPreviewFactory.emptyStack()),
        careCircleRepo: CareCircleRepository(stack: SupervisorPreviewFactory.emptyStack())
    )
    .environmentObject(AuthService())
}
#endif
