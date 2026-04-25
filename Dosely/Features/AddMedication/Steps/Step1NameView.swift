import SwiftUI

struct Step1NameView: View {
    @EnvironmentObject var state: AddMedicationState
    @FocusState private var focused: Bool
    @State private var showingScan = false

    var body: some View {
        StepShell(
            stepNumber: 1,
            question: "What's the name of the medication?",
            primaryTitle: "Next",
            primaryEnabled: !trimmed.isEmpty,
            primaryAction: { state.path.append(.dose) }
        ) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                Button(action: { showingScan = true }) {
                    Label("Scan a prescription label", systemImage: "camera.fill")
                        .dsBodyLarge()
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                        .background(Color.dsPrimary)
                        .cornerRadius(DSSpacing.rMd)
                }
                .accessibilityLabel("Scan a prescription label with the camera")

                Text("Or type it in")
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
                    .frame(maxWidth: .infinity)

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
            }
        }
        .fullScreenCover(isPresented: $showingScan) {
            ScanCoordinator(
                onComplete: { parsed in
                    state.applyScanned(parsed)
                    showingScan = false
                },
                onAbandonToManual: {
                    showingScan = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        focused = true
                    }
                }
            )
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
