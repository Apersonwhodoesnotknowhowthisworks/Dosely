import SwiftUI

struct DebugToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                Button(action: { ReminderScheduler.scheduleTestNotification(after: 30) }) {
                    Label("Test notification (30s)", systemImage: "bell.badge")
                        .dsCaption()
                        .foregroundColor(.dsPrimary)
                        .padding(.horizontal, DSSpacing.sm)
                        .frame(minHeight: 32)
                        .background(Color.dsSurface)
                        .cornerRadius(DSSpacing.rSm)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSSpacing.rSm)
                                .stroke(Color.dsPrimary, lineWidth: 1)
                        )
                }
                .accessibilityLabel("DEBUG: schedule test notification in 30 seconds")
                .padding(.trailing, DSSpacing.md)
                .padding(.top, DSSpacing.xs)
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    func debugToolbar() -> some View {
        modifier(DebugToolbarModifier())
    }
}
