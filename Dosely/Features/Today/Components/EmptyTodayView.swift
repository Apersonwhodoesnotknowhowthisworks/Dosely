import SwiftUI

struct EmptyTodayView: View {
    var body: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "pills.fill")
                .font(.system(size: 56))
                .foregroundColor(.dsPrimary)
                .accessibilityHidden(true)
            Text("No medications scheduled today")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
            Text("Tap + to add one")
                .dsBodyLarge()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No medications scheduled today. Tap the plus button to add one.")
    }
}
