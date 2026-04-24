import SwiftUI

struct TodayView: View {
    @StateObject private var viewModel: TodayViewModel
    private let repository: MedicationRepository

    init(repository: MedicationRepository = MedicationRepository()) {
        self.repository = repository
        _viewModel = StateObject(wrappedValue: TodayViewModel(repository: repository))
    }

    var body: some View {
        TabView {
            todayTab
                .tabItem {
                    Label("Today", systemImage: "house.fill")
                }
            historyTab
                .tabItem {
                    Label("History", systemImage: "calendar")
                }
        }
        .tint(.dsPrimary)
    }

    // MARK: - Today tab

    private var todayTab: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.subtitleFormatter.string(from: Date()))
                    .dsBodyLarge()
                    .foregroundColor(.dsTextSecondary)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.bottom, DSSpacing.sm)
                    .accessibilityLabel("Today is \(Self.subtitleFormatter.string(from: Date()))")

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { print("TODO add med") }) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                    }
                    .accessibilityLabel("Add medication")
                    .accessibilityHint("Opens the new medication form")
                }
            }
        }
        .task {
            #if DEBUG
            await SeedData.seedIfEmpty(using: repository)
            #endif
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.isLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.doses.isEmpty {
            EmptyTodayView()
        } else {
            ScrollView {
                LazyVStack(spacing: DSSpacing.md) {
                    ForEach(viewModel.doses) { dose in
                        DoseCardView(
                            dose: dose,
                            onTake: { Task { await viewModel.markTaken(dose) } },
                            onSkip: { Task { await viewModel.skip(dose) } },
                            onSnooze: { print("TODO snooze") }
                        )
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.bottom, DSSpacing.xl)
            }
        }
    }

    // MARK: - History tab

    private var historyTab: some View {
        NavigationStack {
            VStack {
                Text("History tab coming in Prompt 6")
                    .dsBodyLarge()
                    .foregroundColor(.dsTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(DSSpacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle("History")
        }
    }

    private static let subtitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()
}

// MARK: - Previews

#if DEBUG
@MainActor
private enum TodayPreviewFactory {
    static func emptyRepo() -> MedicationRepository {
        MedicationRepository(stack: CoreDataStack(inMemory: true))
    }

    static func repo(withDoses specs: [PreviewDoseSpec]) async -> MedicationRepository {
        let repo = MedicationRepository(stack: CoreDataStack(inMemory: true))
        for spec in specs {
            let med = await repo.saveMedication(
                name: spec.name,
                dose: spec.dose,
                pillsPerDose: 1,
                foodRule: spec.foodRule,
                notes: spec.notes,
                currentSupply: 30,
                pillPhotoData: nil,
                schedules: [ScheduleInput(timeOfDay: spec.timeOfDay, daysOfWeek: 127)]
            )
            if let status = spec.logStatus, let medID = med.id {
                let scheduledToday = TodayViewModel.date(for: spec.timeOfDay, on: Date()) ?? Date()
                _ = await repo.logDose(
                    medicationID: medID,
                    scheduledTime: scheduledToday,
                    actualTime: status == "taken" ? scheduledToday.addingTimeInterval(120) : nil,
                    status: status
                )
            }
        }
        return repo
    }
}

private struct PreviewDoseSpec {
    let name: String
    let dose: String
    let timeOfDay: String
    let foodRule: String
    let notes: String?
    let logStatus: String?
}

#Preview("Today · empty") {
    TodayView(repository: TodayPreviewFactory.emptyRepo())
}

#Preview("Today · 1 upcoming") {
    // Use a far-future time so it stays "upcoming" all day.
    TodayView(repository: MedicationRepository(stack: CoreDataStack(inMemory: true)))
        .task {
            // The view's own .task will seed because DEBUG is on and the store is empty.
        }
}

#Preview("Today · 4 mixed") {
    AsyncPreview {
        let repo = await TodayPreviewFactory.repo(withDoses: [
            PreviewDoseSpec(name: "Metformin",   dose: "500mg", timeOfDay: "08:00", foodRule: "with",    notes: "With water.",        logStatus: "taken"),
            PreviewDoseSpec(name: "Lisinopril",  dose: "10mg",  timeOfDay: "09:00", foodRule: "either",  notes: "Blood pressure.",    logStatus: "late"),
            PreviewDoseSpec(name: "Atorvastatin", dose: "20mg",  timeOfDay: "20:00", foodRule: "either",  notes: "Cholesterol.",       logStatus: nil),
            PreviewDoseSpec(name: "Metformin",   dose: "500mg", timeOfDay: "21:00", foodRule: "with",    notes: "Evening dose.",      logStatus: nil)
        ])
        return TodayView(repository: repo)
    }
}

private struct AsyncPreview<Content: View>: View {
    @State private var content: Content?
    let builder: () async -> Content

    init(@ViewBuilder _ builder: @escaping () async -> Content) {
        self.builder = builder
    }

    var body: some View {
        Group {
            if let content { content } else { ProgressView() }
        }
        .task {
            if content == nil { content = await builder() }
        }
    }
}
#endif
