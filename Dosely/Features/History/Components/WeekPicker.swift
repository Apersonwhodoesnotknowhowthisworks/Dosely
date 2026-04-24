import SwiftUI

struct WeekPicker: View {
    let label: String
    let canGoBack: Bool
    let canGoForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(canGoBack ? .dsPrimary : Color.gray.opacity(0.4))
                    .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
            }
            .disabled(!canGoBack)
            .accessibilityLabel("Previous week")

            Text(label)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .frame(maxWidth: .infinity)

            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(canGoForward ? .dsPrimary : Color.gray.opacity(0.4))
                    .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
            }
            .disabled(!canGoForward)
            .accessibilityLabel("Next week")
        }
        .padding(.horizontal, DSSpacing.lg)
    }
}
