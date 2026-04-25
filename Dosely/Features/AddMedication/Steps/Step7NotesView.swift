import SwiftUI

struct Step7NotesView: View {
    @EnvironmentObject var state: AddMedicationState

    var body: some View {
        StepShell(
            stepNumber: 7,
            question: L("addmed.step7.question"),
            primaryAction: { state.path.append(.review) },
            secondaryTitle: L("common.skip"),
            secondaryAction: {
                state.notes = ""
                state.path.append(.review)
            }
        ) {
            TextEditor(text: $state.notes)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(DSSpacing.sm)
                .frame(minHeight: 160)
                .background(Color.dsSurface)
                .cornerRadius(DSSpacing.rMd)
                .accessibilityLabel(Text("addmed.step7.placeholder"))
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { Step7NotesView() }
        .environmentObject(AddMedicationState())
}
#endif
