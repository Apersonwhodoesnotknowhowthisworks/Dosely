import SwiftUI

struct MedicalDisclaimerView: View {
    var onAccept: () -> Void

    var body: some View {
        ZStack {
            Color.dsBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.dsWarning)
                    .accessibilityHidden(true)

                Text("Before you continue")
                    .dsTitleLarge()
                    .foregroundColor(.dsTextPrimary)

                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        Text("Dosely is a reminder tool. It is not a substitute for professional medical advice, diagnosis, or treatment.")
                            .dsBodyLarge()
                            .foregroundColor(.dsTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Always consult your doctor or pharmacist about medications, dosage changes, side effects, and interactions. If you think you're having a medical emergency, call emergency services immediately.")
                            .dsBodyLarge()
                            .foregroundColor(.dsTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("By tapping “I understand,” you confirm that you'll rely on your healthcare provider for medical decisions and use Dosely as a personal aid only.")
                            .dsBodyLarge()
                            .foregroundColor(.dsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, DSSpacing.sm)
                }

                Button(action: onAccept) {
                    Text("I understand")
                        .dsBodyLarge()
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                        .background(Color.dsPrimary)
                        .cornerRadius(DSSpacing.rMd)
                }
                .accessibilityLabel("I understand and accept the medical disclaimer")
            }
            .padding(DSSpacing.lg)
        }
    }
}

#if DEBUG
#Preview {
    MedicalDisclaimerView(onAccept: {})
}
#endif
