import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel
    @State private var selectedCell: GridCell?

    init(repository: MedicationRepository = MedicationRepository()) {
        _viewModel = StateObject(wrappedValue: HistoryViewModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                WeekPicker(
                    label: viewModel.weekLabel(),
                    canGoBack: viewModel.canGoBack,
                    canGoForward: viewModel.canGoForward,
                    onBack: { viewModel.goBack() },
                    onForward: { viewModel.goForward() }
                )

                if viewModel.isLoaded {
                    WeekGridView(cells: viewModel.cells) { cell in
                        selectedCell = cell
                    }
                    .padding(.horizontal, DSSpacing.lg)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }

                summaryText
                    .padding(.horizontal, DSSpacing.lg)

                Spacer()
            }
            .padding(.top, DSSpacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle("History")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: viewModel.goForward()
                case .decrement: viewModel.goBack()
                @unknown default: break
                }
            }
        }
        .task { await viewModel.load() }
        .sheet(item: $selectedCell) { cell in
            WeekCellDetailView(cell: cell)
        }
    }

    private var summaryText: some View {
        let s = viewModel.summary
        let title = viewModel.isCurrentWeek ? "This week" : viewModel.weekLabel()
        let text: String = {
            if s.scheduledCount == 0 {
                return "\(title): no doses logged yet"
            }
            return "\(title): \(s.adherencePercent)% adherence (\(s.takenCount)/\(s.scheduledCount) doses taken)"
        }()
        return Text(text)
            .dsBodyLarge()
            .foregroundColor(.dsTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private enum HistoryPreviewFactory {
    static func emptyRepo() -> MedicationRepository {
        MedicationRepository(stack: CoreDataStack(inMemory: true))
    }

    static func mixedRepo() async -> MedicationRepository {
        let repo = MedicationRepository(stack: CoreDataStack(inMemory: true))
        let cal = Calendar(identifier: .iso8601)
        let now = Date()
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return repo }

        let morning = await repo.saveMedication(
            name: "Metformin", dose: "500mg", pillsPerDose: 1, foodRule: "with",
            notes: nil, currentSupply: 60, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)]
        )
        let evening = await repo.saveMedication(
            name: "Lisinopril", dose: "10mg", pillsPerDose: 1, foodRule: "either",
            notes: nil, currentSupply: 30, pillPhotoData: nil,
            schedules: [ScheduleInput(timeOfDay: "18:00", daysOfWeek: 127)]
        )

        // Day 0 Mon: taken
        _ = await repo.logDose(medicationID: morning.id!, scheduledTime: cal.date(byAdding: .hour, value: 8, to: weekStart)!, actualTime: cal.date(byAdding: .minute, value: 5, to: cal.date(byAdding: .hour, value: 8, to: weekStart)!), status: "taken")
        // Day 1 Tue: missed
        _ = await repo.logDose(medicationID: evening.id!, scheduledTime: cal.date(byAdding: .hour, value: 42, to: weekStart)!, actualTime: nil, status: "missed")
        // Day 2 Wed: late
        _ = await repo.logDose(medicationID: morning.id!, scheduledTime: cal.date(byAdding: .hour, value: 56, to: weekStart)!, actualTime: nil, status: "late")
        return repo
    }
}

#Preview("History · empty") {
    HistoryView(repository: HistoryPreviewFactory.emptyRepo())
}

#Preview("History · mixed week") {
    AsyncHistoryPreview { await HistoryPreviewFactory.mixedRepo() }
}

private struct AsyncHistoryPreview: View {
    @State private var repo: MedicationRepository?
    let builder: () async -> MedicationRepository

    var body: some View {
        Group {
            if let repo { HistoryView(repository: repo) } else { ProgressView() }
        }
        .task { if repo == nil { repo = await builder() } }
    }
}
#endif
