import SwiftUI

struct EmptyTodayView: View {
    var body: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "pills.fill")
                .font(.system(size: 56))
                .foregroundColor(.dsPrimary)
                .accessibilityHidden(true)
            Text("today.empty.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
            Text("today.empty.hint")
                .dsBodyLarge()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("today.empty.combined"))
    }
}
