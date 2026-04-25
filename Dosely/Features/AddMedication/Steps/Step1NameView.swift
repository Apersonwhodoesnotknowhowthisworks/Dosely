import SwiftUI

struct Step1NameView: View {
    @EnvironmentObject var state: AddMedicationState
    @AppStorage("app_language") private var language: String = ""
    @FocusState private var focused: Bool
    @State private var showingScan = false

    var body: some View {
        StepShell(
            stepNumber: 1,
            question: L("addmed.step1.question"),
            primaryEnabled: !trimmed.isEmpty,
            primaryAction: { state.path.append(.dose) }
        ) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                Button(action: { showingScan = true }) {
                    Label("addmed.step1.scan", systemImage: "camera.fill")
                        .dsBodyLarge()
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                        .background(Color.dsPrimary)
                        .cornerRadius(DSSpacing.rMd)
                }
                .accessibilityLabel(Text("addmed.step1.scan"))

                if language == "pa" {
                    Text("addmed.step1.scan.englishonly")
                        .dsCaption()
                        .foregroundColor(.dsTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }

                Text("addmed.step1.ortypeit")
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
                    .frame(maxWidth: .infinity)

                TextField(L("addmed.step1.placeholder"), text: $state.name)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel(Text("addmed.step1.placeholder"))
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
