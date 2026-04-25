import SwiftUI

struct Step2DoseView: View {
    @EnvironmentObject var state: AddMedicationState
    @FocusState private var focused: Bool

    var body: some View {
        StepShell(
            stepNumber: 2,
            question: L("addmed.step2.question"),
            primaryEnabled: !state.dose.trimmingCharacters(in: .whitespaces).isEmpty,
            primaryAction: { state.path.append(.frequency) }
        ) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                TextField(L("addmed.step2.placeholder"), text: $state.dose)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text("addmed.step2.placeholder"))
                    .onAppear { focused = true }

                Text("addmed.step2.pillsperdose")
                    .dsBodyLarge()
                    .foregroundColor(.dsTextSecondary)
                    .padding(.top, DSSpacing.sm)

                HStack {
                    Text("\(state.pillsPerDose)")
                        .dsTitleMedium()
                        .foregroundColor(.dsTextPrimary)
                        .frame(minWidth: 40, alignment: .leading)
                    Spacer()
                    Stepper(
                        L("addmed.step2.pillsperdose"),
                        value: $state.pillsPerDose,
                        in: 1...10
                    )
                    .labelsHidden()
                    .accessibilityLabel(L("addmed.step2.pills.a11y", state.pillsPerDose))
                }
                .padding(DSSpacing.md)
                .frame(minHeight: DSSpacing.minTapTarget)
                .background(Color.dsSurface)
                .cornerRadius(DSSpacing.rMd)
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { Step2DoseView() }
        .environmentObject(AddMedicationState())
}
#endif
