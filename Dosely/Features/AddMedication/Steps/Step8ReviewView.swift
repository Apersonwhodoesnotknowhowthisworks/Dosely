import SwiftUI

struct Step8ReviewView: View {
    @EnvironmentObject var state: AddMedicationState
    @State private var showingDetail = false
    var onSave: () -> Void

    var body: some View {
        StepShell(
            stepNumber: 8,
            question: L("addmed.step8.title"),
            primaryTitle: L("addmed.step8.save"),
            primaryAction: onSave
        ) {
            ScrollView {
                VStack(spacing: DSSpacing.sm) {
                    row(label: L("addmed.step8.row.name"),
                        value: state.name.isEmpty ? L("addmed.empty") : state.name,
                        jumpTo: nil)
                    row(label: L("addmed.step8.row.dose"),
                        value: doseText,
                        jumpTo: .dose)
                    row(label: L("addmed.step8.row.schedule"),
                        value: scheduleText,
                        jumpTo: .frequency)
                    row(label: L("addmed.step8.row.food"),
                        value: foodText,
                        jumpTo: .foodRule)
                    row(label: L("addmed.step8.row.supply"),
                        value: L("addmed.supply.pills", state.currentSupply),
                        jumpTo: .supply)
                    row(label: L("addmed.step8.row.notes"),
                        value: state.notes.isEmpty ? L("addmed.empty") : state.notes,
                        jumpTo: .notes)

                    if !state.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button(action: { showingDetail = true }) {
                            Label("addmed.step8.learnmore", systemImage: "info.circle")
                                .dsBodyLarge()
                                .foregroundColor(.dsPrimary)
                                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DSSpacing.rMd)
                                        .stroke(Color.dsPrimary, lineWidth: 1.5)
                                )
                        }
                        .accessibilityLabel(Text("addmed.step8.learnmore"))
                        .padding(.top, DSSpacing.sm)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .sheet(isPresented: $showingDetail) {
            MedicationDetailView(name: state.name, dose: state.dose)
        }
    }

    private func row(label: String, value: String, jumpTo step: AddStep?) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(label)
                    .dsCaption()
                    .foregroundColor(.dsTextSecondary)
                Text(value)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let step {
                Button(L("common.edit")) { jump(to: step) }
                    .dsBodyRegular()
                    .foregroundColor(.dsPrimary)
                    .frame(minHeight: DSSpacing.minTapTarget)
            }
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private func jump(to step: AddStep) {
        guard let idx = state.path.firstIndex(of: step) else { return }
        state.path = Array(state.path.prefix(idx + 1))
    }

    private var pillWord: String {
        state.pillsPerDose == 1 ? L("today.dose.pill") : L("today.dose.pills")
    }

    private var doseText: String {
        "\(state.dose) · \(state.pillsPerDose) \(pillWord)"
    }

    private var foodText: String {
        switch state.foodRule {
        case "with":    return L("addmed.food.with")
        case "without": return L("addmed.food.without")
        default:        return L("addmed.food.either")
        }
    }

    private var scheduleText: String {
        let times = state.doseTimes
            .map { LocalizedFormatters.timeFormatter.string(from: $0) }
            .joined(separator: ", ")
        let per = state.timesPerDay == 1
            ? L("addmed.schedule.oncedaily")
            : L("addmed.schedule.timesperday", state.timesPerDay)
        return "\(per) · \(times)"
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        Step8ReviewView(onSave: {})
    }
    .environmentObject({
        let s = AddMedicationState()
        s.name = "Metformin"
        s.dose = "500mg"
        s.pillsPerDose = 1
        s.timesPerDay = 2
        s.prepopulateTimes()
        s.foodRule = "with"
        s.currentSupply = 60
        s.notes = "Take with a full glass of water."
        s.path = [.dose, .frequency, .times, .foodRule, .supply, .notes, .review]
        return s
    }())
}
#endif
