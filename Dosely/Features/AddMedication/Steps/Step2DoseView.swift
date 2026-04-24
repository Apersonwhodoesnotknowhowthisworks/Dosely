import SwiftUI

struct Step2DoseView: View {
    @EnvironmentObject var state: AddMedicationState
    @FocusState private var focused: Bool

    var body: some View {
        StepShell(
            stepNumber: 2,
            question: "How much per dose?",
            primaryTitle: "Next",
            primaryEnabled: !state.dose.trimmingCharacters(in: .whitespaces).isEmpty,
            primaryAction: { state.path.append(.frequency) }
        ) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                TextField("e.g. 10mg", text: $state.dose)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Dose amount")
                    .onAppear { focused = true }

                Text("Pills per dose")
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
                        "Pills per dose",
                        value: $state.pillsPerDose,
                        in: 1...10
                    )
                    .labelsHidden()
                    .accessibilityLabel("Pills per dose, currently \(state.pillsPerDose)")
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
