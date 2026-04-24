import SwiftUI

struct Step1NameView: View {
    @EnvironmentObject var state: AddMedicationState
    @FocusState private var focused: Bool

    var body: some View {
        StepShell(
            stepNumber: 1,
            question: "What's the name of the medication?",
            primaryTitle: "Next",
            primaryEnabled: !trimmed.isEmpty,
            primaryAction: { state.path.append(.dose) }
        ) {
            TextField("Medication name", text: $state.name)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .padding(DSSpacing.md)
                .frame(minHeight: DSSpacing.minTapTarget)
                .background(Color.dsSurface)
                .cornerRadius(DSSpacing.rMd)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .accessibilityLabel("Medication name")
                .onAppear { focused = true }
        }
    }

    private var trimmed: String {
        state.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if DEBUG
#Preview {
    NavigationStack { Step1NameView() }
        .environmentObject(AddMedicationState())
}
#endif
