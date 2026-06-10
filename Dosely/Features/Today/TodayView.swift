import SwiftUI

struct TodayView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var viewModel: TodayViewModel
    private let repository: MedicationRepository
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var detailDose: TodayDose?
    @State private var refreshErrorMessage: String?
    @State private var confirmingEmergency = false
    @State private var emergencySentToastVisible = false
    @State private var showingMedicalID = false
    private let alertsRepo: AlertsRepository

    init(repository: MedicationRepository = MedicationRepository(),
         alertsRepo: AlertsRepository = AlertsRepository()) {
        self.repository = repository
        self.alertsRepo = alertsRepo
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
                    DoselyBanner()

                    Text(LocalizedFormatters.fullDateFormatter.string(from: Date()))
                        .dsBodyLarge()
                        .foregroundColor(.dsTextSecondary)
                        .padding(.horizontal, DSSpacing.lg)
                        .padding(.bottom, DSSpacing.sm)
                        .accessibilityLabel(L("today.subtitle.todayis",
                                              LocalizedFormatters.fullDateFormatter.string(from: Date()) as NSString))

                    content

                    // Client action tiles. The blue Medical ID tile is a
                    // read-only, paramedic-facing view of allergies /
                    // conditions / contacts — deliberately distinct from
                    // the red "I need help" alert button below (different
                    // colour, icon, copy). The alert button stays
                    // device-client-only (managed clients don't sign in
                    // themselves); the Medical ID tile shows for any client.
                    if isClientActor {
                        VStack(spacing: DSSpacing.md) {
                            medicalIDButton
                            if isDeviceClient {
                                emergencyButton
                            }
                        }
                        .padding(.horizontal, DSSpacing.lg)
                        .padding(.top, DSSpacing.lg)
                        .padding(.bottom, DSSpacing.xl)
                    }
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
                // Add-medication is a supervisor write affordance — hidden from
                // device_client / managed_client signed in on their own device,
                // and from a supervisor in act-as mode (the actor's role is a
                // client role, so the lens hides it for fidelity — Part 8a).
                if Self.shouldShowAddMedication(role: authService.actorPerson?.role) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { showingAdd = true }) {
                            Image(systemName: "plus")
                                .font(.title2.weight(.semibold))
                                .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                        }
                        .accessibilityLabel(Text("today.add"))
                    }
                }
            }
            .debugToolbar()
        }
        // Keyed on the ACTING person so toggling act-as cancels and restarts
        // the load for the new lens — keying on currentPerson would leave the
        // task running for the supervisor's own (empty) schedule, the same
        // one-shot-snapshot class of bug as the June 7/8 carecircle fixes.
        .task(id: authService.actorPerson?.id) {
            guard let personID = authService.actorPerson?.id else { return }
            #if DEBUG
            // NEVER seed while acting-as: the signed-in actor is the
            // primary, so saveMedication's guard would PASS and write demo
            // medications into the family member's REAL record (shared
            // Firestore, every device). Outside act-as this is the original
            // behavior — actor == displayed person, and a client actor is
            // rejected by the primary-only guard as before.
            if authService.actingPersonID == nil {
                await SeedData.seedIfEmpty(using: repository, personID: personID, actorPersonID: personID)
            }
            #endif
            await MissedDoseChecker(repository: repository).run(for: personID)
            if let circleID = authService.currentPerson?.careCircle?.id {
                await RefillAlertDetector().run(in: circleID)
            }
            await viewModel.load(personID: personID)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                await MissedDoseChecker(repository: repository).run(for: personID)
                if let circleID = authService.currentPerson?.careCircle?.id {
                    await RefillAlertDetector().run(in: circleID)
                }
                await viewModel.load(personID: personID)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddMedicationFlow(repository: repository) {
                if let personID = authService.actorPerson?.id {
                    Task { await viewModel.load(personID: personID) }
                }
            }
            .environmentObject(authService)
        }
        .sheet(isPresented: $showingSettings) {
            // Deliberately NOT lens-aware: settings (language, accessibility,
            // sign-out, family management) belong to the device + Firebase
            // identity, not to whoever's view the supervisor is looking
            // through — see the Part 8e decision in the build_log entry.
            SettingsSheet()
        }
        .sheet(isPresented: $showingMedicalID) {
            // The acting person's Medical ID — in act-as the supervisor sees
            // the target's allergies/conditions, not their own (Part 8a).
            if let person = authService.actorPerson {
                EmergencyMedicalIDView(person: person)
            }
        }
        .alert(L("today.client.emergency.confirm.title"),
               isPresented: $confirmingEmergency) {
            Button(L("today.client.emergency.confirm.action"), role: .destructive) {
                Task { await fireEmergencyAlert() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text("today.client.emergency.confirm.body")
        }
        .overlay(alignment: .top) {
            if emergencySentToastVisible {
                Text("today.client.emergency.sent")
                    .dsBodyRegular()
                    .foregroundColor(.white)
                    .padding(DSSpacing.md)
                    .frame(maxWidth: .infinity)
                    .background(Color.dsSuccess)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: emergencySentToastVisible)
        .sheet(item: $detailDose) { dose in
            MedicationDetailView(
                name: dose.medication.name ?? "",
                dose: dose.medication.dose ?? "",
                pillPhotoData: dose.medication.pillPhotoData,
                patientPersonID: dose.medication.personID
            )
        }
        // Reload when the app returns from background so that doses logged from a
        // notification action (TOOK_IT) surface without waiting for the 5-min poll.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let personID = authService.actorPerson?.id else { return }
            Task {
                await MissedDoseChecker(repository: repository).run(for: personID)
                if let circleID = authService.currentPerson?.careCircle?.id {
                    await RefillAlertDetector().run(in: circleID)
                }
                await viewModel.load(personID: personID)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if authService.actorPerson == nil || !viewModel.isLoaded {
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
        guard let split = Self.doseLogAttribution(
            currentPersonID: authService.currentPerson?.id,
            actorPersonID: authService.actorPerson?.id
        ) else { return }
        await viewModel.markTaken(dose, loggedByPersonID: split.loggedBy, personID: split.scope)
    }

    /// The D5 attribution split, pure + static so the tests pin the decision
    /// without hosting the view: `loggedBy` is ALWAYS the signed-in identity
    /// (the audit trail records who actually tapped — the supervisor in
    /// act-as mode), while the reload `scope` is the acting person, whose
    /// dose cards are on screen. Outside act-as the two are the same person
    /// and behavior is unchanged. Used by both markTaken and skip.
    static func doseLogAttribution(
        currentPersonID: UUID?,
        actorPersonID: UUID?
    ) -> (loggedBy: UUID, scope: UUID)? {
        guard let loggedBy = currentPersonID, let scope = actorPersonID else { return nil }
        return (loggedBy: loggedBy, scope: scope)
    }

    // MARK: - Emergency button

    private var isDeviceClient: Bool {
        authService.actorPerson?.role == Roles.deviceClient
    }

    /// Any non-supervisor actor — a device client or a managed client.
    /// Delegates to the Medical ID eligibility rule so the client-tile
    /// gate and the viewer share one definition: supervisors manage
    /// their own emergency info elsewhere. Reads the ACTING person so the
    /// act-as lens renders the client's true surface (Part 8a).
    private var isClientActor: Bool {
        EmergencyMedicalIDViewModel.isEligibleForMedicalID(role: authService.actorPerson?.role)
    }

    /// Whether the add-medication "+" toolbar affordance should be shown.
    /// Supervisor-only (both flavours — a secondary tapping it still hits the
    /// repository's primary-only guard at save time); hidden from
    /// device_client / managed_client. Pure + static so `TodayViewTests` can
    /// pin every role branch without rendering.
    static func shouldShowAddMedication(role: String?) -> Bool {
        Roles.isAnySupervisor(role)
    }

    private var medicalIDButton: some View {
        Button(action: { showingMedicalID = true }) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "heart.text.square.fill")
                    .accessibilityHidden(true)
                Text("emergency.medicalid.button.title")
                    .dsBodyLarge()
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.dsPrimary)
            .cornerRadius(DSSpacing.rLg)
        }
        .accessibilityLabel(Text("emergency.medicalid.button.title"))
    }

    private var emergencyButton: some View {
        Button(action: { confirmingEmergency = true }) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text("today.client.emergency")
                    .dsBodyLarge()
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.dsDanger)
            .cornerRadius(DSSpacing.rLg)
        }
        .accessibilityLabel(Text("today.client.emergency"))
    }

    private func fireEmergencyAlert() async {
        // The alert is about the ACTING person — in act-as the supervisor is
        // raising help on the target's behalf, so the alert carries the
        // target's id and name, not the supervisor's (Part 8a).
        guard let person = authService.actorPerson,
              let personID = person.id,
              let circleID = person.careCircle?.id else { return }
        let alertID = UUID().uuidString
        let alert = FirestoreModels.FAlert(
            id: alertID,
            type: FirestoreModels.AlertType.emergency,
            personID: personID.uuidString,
            medicationID: nil,
            scheduledTime: nil,
            createdAt: Date(),
            payload: ["personName": person.name ?? ""],
            acknowledgedBy: nil,
            acknowledgedByName: nil,
            acknowledgedAt: nil,
            lastModified: nil
        )
        do {
            _ = try await alertsRepo.createIfAbsent(alert, in: circleID)
            await MainActor.run {
                emergencySentToastVisible = true
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                emergencySentToastVisible = false
            }
        } catch {
            // The toast doesn't double as an error surface here —
            // emergency button users shouldn't be hunting through copy.
            // Silent fail is acceptable; the listener will surface the
            // alert once network returns and the queued write replays.
        }
    }

    private func skip(_ dose: TodayDose) async {
        guard let split = Self.doseLogAttribution(
            currentPersonID: authService.currentPerson?.id,
            actorPersonID: authService.actorPerson?.id
        ) else { return }
        await viewModel.skip(dose, loggedByPersonID: split.loggedBy, personID: split.scope)
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
