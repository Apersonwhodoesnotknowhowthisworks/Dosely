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

                Text("disclaimer.title")
                    .dsTitleLarge()
                    .foregroundColor(.dsTextPrimary)

                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        Text("disclaimer.body1")
                            .dsBodyLarge()
                            .foregroundColor(.dsTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("disclaimer.body2")
                            .dsBodyLarge()
                            .foregroundColor(.dsTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("disclaimer.body3")
                            .dsBodyLarge()
                            .foregroundColor(.dsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, DSSpacing.sm)
                }

                Button(action: onAccept) {
                    Text("disclaimer.understand")
                        .dsBodyLarge()
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                        .background(Color.dsPrimary)
                        .cornerRadius(DSSpacing.rMd)
                }
                .accessibilityLabel(Text("disclaimer.understand"))
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
