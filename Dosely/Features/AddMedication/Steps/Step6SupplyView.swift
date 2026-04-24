import SwiftUI

struct Step6SupplyView: View {
    @EnvironmentObject var state: AddMedicationState

    var body: some View {
        StepShell(
            stepNumber: 6,
            question: "How many pills do you have right now?",
            primaryTitle: "Next",
            primaryAction: { state.path.append(.notes) }
        ) {
            HStack {
                Text("\(state.currentSupply)")
                    .dsTitleLarge()
                    .foregroundColor(.dsTextPrimary)
                    .frame(minWidth: 80, alignment: .leading)
                Spacer()
                Stepper(
                    "Current supply",
                    value: $state.currentSupply,
                    in: 0...200
                )
                .labelsHidden()
                .accessibilityLabel("Pills on hand, currently \(state.currentSupply)")
            }
            .padding(DSSpacing.md)
            .frame(minHeight: DSSpacing.minTapTarget)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { Step6SupplyView() }
        .environmentObject(AddMedicationState())
}
#endif
