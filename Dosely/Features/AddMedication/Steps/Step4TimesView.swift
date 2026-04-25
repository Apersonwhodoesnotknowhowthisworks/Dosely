import SwiftUI

struct Step4TimesView: View {
    @EnvironmentObject var state: AddMedicationState

    var body: some View {
        StepShell(
            stepNumber: 4,
            question: L("addmed.step4.question"),
            primaryEnabled: !state.doseTimes.isEmpty,
            primaryAction: { state.path.append(.foodRule) }
        ) {
            VStack(spacing: DSSpacing.sm) {
                ForEach(state.doseTimes.indices, id: \.self) { idx in
                    HStack {
                        Text(L("addmed.step4.dose", idx + 1))
                            .dsBodyLarge()
                            .foregroundColor(.dsTextSecondary)
                        Spacer()
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { state.doseTimes[idx] },
                                set: { state.doseTimes[idx] = $0 }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .accessibilityLabel(L("addmed.step4.time.a11y", idx + 1))
                    }
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
                }
            }
        }
        .onAppear {
            if state.doseTimes.count != state.timesPerDay {
                state.prepopulateTimes()
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { Step4TimesView() }
        .environmentObject({
            let s = AddMedicationState()
            s.timesPerDay = 3
            s.prepopulateTimes()
            return s
        }())
}
#endif
