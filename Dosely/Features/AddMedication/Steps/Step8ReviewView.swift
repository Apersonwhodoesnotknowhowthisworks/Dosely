import SwiftUI

struct Step8ReviewView: View {
    @EnvironmentObject var state: AddMedicationState
    var onSave: () -> Void

    var body: some View {
        StepShell(
            stepNumber: 8,
            question: "Review and save",
            primaryTitle: "Save medication",
            primaryAction: onSave
        ) {
            ScrollView {
                VStack(spacing: DSSpacing.sm) {
                    row(label: "Name",     value: state.name.isEmpty ? "—" : state.name, jumpTo: nil)
                    row(label: "Dose",     value: "\(state.dose) · \(state.pillsPerDose) \(pillWord)", jumpTo: .dose)
                    row(label: "Schedule", value: scheduleText, jumpTo: .frequency)
                    row(label: "Food",     value: foodText, jumpTo: .foodRule)
                    row(label: "Supply",   value: "\(state.currentSupply) pills", jumpTo: .supply)
                    row(label: "Notes",    value: state.notes.isEmpty ? "—" : state.notes, jumpTo: .notes)
                }
            }
            .frame(maxHeight: 420)
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
                Button("Edit") { jump(to: step) }
                    .dsBodyRegular()
                    .foregroundColor(.dsPrimary)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .accessibilityLabel("Edit \(label.lowercased())")
            }
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private func jump(to step: AddStep) {
        // Truncate the path so we land on `step` as the top.
        guard let idx = state.path.firstIndex(of: step) else { return }
        state.path = Array(state.path.prefix(idx + 1))
    }

    private var pillWord: String { state.pillsPerDose == 1 ? "pill" : "pills" }

    private var foodText: String {
        switch state.foodRule {
        case "with":    return "With food"
        case "without": return "Without food"
        default:        return "Either is fine"
        }
    }

    private var scheduleText: String {
        let times = state.doseTimes.map(AddMedicationState.formatDisplay).joined(separator: ", ")
        let per = state.timesPerDay == 1 ? "Once a day" : "\(state.timesPerDay) times a day"
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
