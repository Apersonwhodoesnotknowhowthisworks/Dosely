import SwiftUI

struct Step7NotesView: View {
    @EnvironmentObject var state: AddMedicationState

    var body: some View {
        StepShell(
            stepNumber: 7,
            question: "Any notes from the doctor?",
            primaryTitle: "Next",
            primaryAction: { state.path.append(.review) },
            secondaryTitle: "Skip",
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
                .accessibilityLabel("Doctor's notes")
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { Step7NotesView() }
        .environmentObject(AddMedicationState())
}
#endif
