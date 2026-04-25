import SwiftUI

struct Step3FrequencyView: View {
    @EnvironmentObject var state: AddMedicationState
    @State private var showingCustom = false
    @State private var customText: String = ""

    var body: some View {
        StepShell(
            stepNumber: 3,
            question: L("addmed.step3.question"),
            primaryTitle: showingCustom ? L("common.next") : nil,
            primaryEnabled: customValid,
            primaryAction: showingCustom ? { commitCustom() } : nil
        ) {
            VStack(spacing: DSSpacing.md) {
                frequencyButton(label: L("addmed.step3.once"),  count: 1)
                frequencyButton(label: L("addmed.step3.twice"), count: 2)
                frequencyButton(label: L("addmed.step3.three"), count: 3)
                frequencyButton(label: L("addmed.step3.four"),  count: 4)

                if showingCustom {
                    HStack {
                        Text("addmed.step3.timesperday")
                            .dsBodyLarge()
                            .foregroundColor(.dsTextPrimary)
                        Spacer()
                        TextField(L("addmed.step3.range"), text: $customText)
                            .dsBodyLarge()
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .accessibilityLabel(Text("addmed.step3.timesperday"))
                    }
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
                } else {
                    Button(action: { showingCustom = true }) {
                        Text("addmed.step3.custom")
                            .dsBodyLarge()
                            .foregroundColor(.dsPrimary)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .background(Color.dsSurface)
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .accessibilityLabel(Text("addmed.step3.custom"))
                }
            }
        }
    }

    private func frequencyButton(label: String, count: Int) -> some View {
        Button(action: { choose(count: count) }) {
            Text(label)
                .dsBodyLarge()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.dsPrimary)
                .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel(label)
    }

    private func choose(count: Int) {
        state.timesPerDay = count
        state.prepopulateTimes()
        state.path.append(.times)
    }

    private var customValid: Bool {
        if let n = Int(customText.trimmingCharacters(in: .whitespaces)), (1...10).contains(n) {
            return true
        }
        return false
    }

    private func commitCustom() {
        guard let n = Int(customText.trimmingCharacters(in: .whitespaces)), (1...10).contains(n) else { return }
        choose(count: n)
    }
}

#if DEBUG
#Preview {
    NavigationStack { Step3FrequencyView() }
        .environmentObject(AddMedicationState())
}
#endif
