import SwiftUI

/// First-launch language gate. Shown once before login. Also reused by the
/// Settings sheet for in-flight language switching.
struct LanguagePickerView: View {
    var onPicked: (String) -> Void
    var showCancel: Bool = false
    var onCancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.dsBackground.ignoresSafeArea()

            VStack(spacing: DSSpacing.xl) {
                Spacer()

                VStack(alignment: .center, spacing: DSSpacing.sm) {
                    Text("Choose your language")
                        .dsTitleLarge()
                        .foregroundColor(.dsTextPrimary)
                        .multilineTextAlignment(.center)
                    Text("ਆਪਣੀ ਭਾਸ਼ਾ ਚੁਣੋ")
                        .dsTitleMedium()
                        .foregroundColor(.dsTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, DSSpacing.lg)

                VStack(spacing: DSSpacing.md) {
                    languageButton(label: "English", code: "en")
                    languageButton(label: "ਪੰਜਾਬੀ", code: "pa")
                }
                .padding(.horizontal, DSSpacing.lg)

                Spacer()

                if showCancel, let onCancel {
                    Button(action: onCancel) {
                        Text("Cancel / ਰੱਦ ਕਰੋ")
                            .dsBodyLarge()
                            .foregroundColor(.dsTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    }
                    .accessibilityLabel("Cancel language selection")
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.bottom, DSSpacing.lg)
                }
            }
        }
    }

    private func languageButton(label: String, code: String) -> some View {
        Button(action: { onPicked(code) }) {
            Text(label)
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget * 2)
                .background(Color.dsPrimary)
                .cornerRadius(DSSpacing.rLg)
        }
        .accessibilityLabel(label)
        .accessibilityHint("Sets the app to \(label)")
    }
}

#if DEBUG
#Preview {
    LanguagePickerView(onPicked: { _ in })
}
#endif
