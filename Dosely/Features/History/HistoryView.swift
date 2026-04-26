import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var authService: AuthService
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
            .navigationTitle(Text("history.title"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: viewModel.goForward()
                case .decrement: viewModel.goBack()
                @unknown default: break
                }
            }
        }
        .task(id: authService.currentPerson?.id) {
            guard let personID = authService.currentPerson?.id else { return }
            await viewModel.load(personID: personID)
        }
        .sheet(item: $selectedCell) { cell in
            WeekCellDetailView(cell: cell)
        }
    }

    private var summaryText: some View {
        let s = viewModel.summary
        let title = viewModel.isCurrentWeek ? L("history.thisweek") : viewModel.weekLabel()
        let text: String = {
            if s.scheduledCount == 0 {
                return L("history.empty", title as NSString)
            }
            return L("history.adherence",
                    title as NSString,
                    s.adherencePercent,
                    s.takenCount,
                    s.scheduledCount)
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
#Preview("History · empty") {
    HistoryView(repository: MedicationRepository(stack: CoreDataStack(inMemory: true)))
        .environmentObject(AuthService())
}
#endif
