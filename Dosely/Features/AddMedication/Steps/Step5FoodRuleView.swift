import SwiftUI

struct Step5FoodRuleView: View {
    @EnvironmentObject var state: AddMedicationState

    var body: some View {
        StepShell(
            stepNumber: 5,
            question: L("addmed.step5.question"),
            primaryAction: nil
        ) {
            VStack(spacing: DSSpacing.md) {
                choiceButton(L("addmed.step5.with"),    value: "with")
                choiceButton(L("addmed.step5.without"), value: "without")
                choiceButton(L("addmed.step5.either"),  value: "either")
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
