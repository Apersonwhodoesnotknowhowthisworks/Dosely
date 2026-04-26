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
            }
        }
        .task(id: refreshKey) {
            await reload()
        }
        .sheet(isPresented: $showingAdd) {
            if let target = pendingAddTargetPersonID {
                AddMedicationFlow(repository: medicationRepo) {
                    Task { await reload() }
                }
                .environmentObject(authService)
                .environment(\.supervisorTargetPersonID, target)
            }
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
                    onLearnMore: { dose in detailDose = dose }
                )

                if let adherence = viewModel.adherence {
                    AdherenceSummaryCard(adherence: adherence) {
                        historyPersonIDOverride = adherence.id
                    }
                }

                AlertsCard(alerts: viewModel.alerts)

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
                             careCircleRepo: careCircleRepo)
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
