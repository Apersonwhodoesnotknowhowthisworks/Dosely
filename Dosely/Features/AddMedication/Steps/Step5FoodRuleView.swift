import SwiftUI

struct Step5FoodRuleView: View {
    @EnvironmentObject var state: AddMedicationState

    var body: some View {
        StepShell(
            stepNumber: 5,
            question: "How should you take this?",
            primaryTitle: nil,
            primaryAction: nil
        ) {
            VStack(spacing: DSSpacing.md) {
                choiceButton("With food",      value: "with")
                choiceButton("Without food",   value: "without")
                choiceButton("Either is fine", value: "either")
            }
        }
    }

    private func choiceButton(_ title: String, value: String) -> some View {
        Button(action: { choose(value) }) {
            Text(title)
                .dsBodyLarge()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.dsPrimary)
                .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel(title)
    }

    private func choose(_ value: String) {
        state.foodRule = value
        state.path.append(.supply)
    }
}

#if DEBUG
#Preview {
    NavigationStack { Step5FoodRuleView() }
        .environmentObject(AddMedicationState())
}
#endif
