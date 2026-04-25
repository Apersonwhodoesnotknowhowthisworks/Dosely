import SwiftUI

struct Step6SupplyView: View {
    @EnvironmentObject var state: AddMedicationState

    var body: some View {
        StepShell(
            stepNumber: 6,
            question: L("addmed.step6.question"),
            primaryAction: { state.path.append(.notes) }
        ) {
            HStack {
                Text("\(state.currentSupply)")
                    .dsTitleLarge()
                    .foregroundColor(.dsTextPrimary)
                    .frame(minWidth: 80, alignment: .leading)
                Spacer()
                Stepper(
                    L("addmed.step6.question"),
                    value: $state.currentSupply,
                    in: 0...200
                )
                .labelsHidden()
                .accessibilityLabel(L("addmed.step6.supply.a11y", state.currentSupply))
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
