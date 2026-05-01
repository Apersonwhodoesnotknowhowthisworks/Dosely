import SwiftUI

struct TodayView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var viewModel: TodayViewModel
    private let repository: MedicationRepository
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var detailDose: TodayDose?
    @State private var refreshErrorMessage: String?

    init(repository: MedicationRepository = MedicationRepository()) {
        self.repository = repository
        _viewModel = StateObject(wrappedValue: TodayViewModel(repository: repository))
    }

    var body: some View {
        TabView {
            todayTab
                .tabItem {
                    Label("today.title", systemImage: "house.fill")
                }
            historyTab
                .tabItem {
                    Label("history.title", systemImage: "calendar")
                }
        }
        .tint(.dsPrimary)
    }

    // MARK: - Today tab

    private var todayTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(LocalizedFormatters.fullDateFormatter.string(from: Date()))
                        .dsBodyLarge()
                        .foregroundColor(.dsTextSecondary)
                        .padding(.horizontal, DSSpacing.lg)
                        .padding(.bottom, DSSpacing.sm)
                        .accessibilityLabel(L("today.subtitle.todayis",
                                              LocalizedFormatters.fullDateFormatter.string(from: Date()) as NSString))

                    content
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .refreshable {
                await PullToRefresh.perform(messageBinding: $refreshErrorMessage)
            }
            .pullToRefreshBanner(message: $refreshErrorMessage)
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
                    Button(action: {
                        print("[UI-DEBUG] + tapped")
                        showingAdd = true
                    }) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                    }
                    .accessibilityLabel(Text("today.add"))
                }
            }
            .debugToolbar()
        }
        .task(id: authService.currentPerson?.id) {
            guard let personID = authService.currentPerson?.id else { return }
            #if DEBUG
            await SeedData.seedIfEmpty(using: repository, personID: personID, actorPersonID: personID)
            #endif
            await MissedDoseChecker(repository: repository).run(for: personID)
            await viewModel.load(personID: personID)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                await MissedDoseChecker(repository: repository).run(for: personID)
                await viewModel.load(personID: personID)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddMedicationFlow(repository: repository) {
                if let personID = authService.currentPerson?.id {
                    Task { await viewModel.load(personID: personID) }
                }
            }
            .environmentObject(authService)
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
        // Reload when the app returns from background so that doses logged from a
        // notification action (TOOK_IT) surface without waiting for the 5-min poll.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let personID = authService.currentPerson?.id else { return }
            Task {
                await MissedDoseChecker(repository: repository).run(for: personID)
                await viewModel.load(personID: personID)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if authService.currentPerson == nil || !viewModel.isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if viewModel.doses.isEmpty {
            EmptyTodayView()
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // Outer .refreshable lives on the parent ScrollView; this
            // intentionally is a plain VStack to avoid nesting scroll
            // views (which kills the pull gesture on the inner one).
            LazyVStack(spacing: DSSpacing.md) {
                ForEach(viewModel.doses) { dose in
                    DoseCardView(
                        dose: dose,
                        onTake: { Task { await markTaken(dose) } },
                        onSkip: { Task { await skip(dose) } },
                        onSnooze: { print("TODO snooze") },
                        onLearnMore: { detailDose = dose }
                    )
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.bottom, DSSpacing.xl)
        }
    }

    private func markTaken(_ dose: TodayDose) async {
        guard let personID = authService.currentPerson?.id else { return }
        await viewModel.markTaken(dose, loggedByPersonID: personID, personID: personID)
    }

    private func skip(_ dose: TodayDose) async {
        guard let personID = authService.currentPerson?.id else { return }
        await viewModel.skip(dose, loggedByPersonID: personID, personID: personID)
    }

    // MARK: - History tab

    private var historyTab: some View {
        HistoryView(repository: repository)
    }

}

// MARK: - Previews

#if DEBUG
@MainActor
private enum TodayPreviewFactory {
    static func emptyRepo() -> MedicationRepository {
        MedicationRepository(stack: CoreDataStack(inMemory: true))
    }
}

#Preview("Today · empty") {
    TodayView(repository: TodayPreviewFactory.emptyRepo())
        .environmentObject(AuthService())
}

#Preview("Today · empty · dark") {
    TodayView(repository: TodayPreviewFactory.emptyRepo())
        .environmentObject(AuthService())
        .preferredColorScheme(.dark)
}
#endif
