import SwiftUI

/// The persistent act-as banner (design decisions D7 / D10): while the
/// supervisor is viewing the app through a family member's lens, this sits
/// above every routed view — TodayView, History, anywhere — as chrome, not
/// scroll content (`safeAreaInset`, so it pushes the view down and never
/// moves with a scroll). It is impossible to be in act-as mode without
/// seeing it, and switching back is always one tap: the whole banner and
/// the explicit pill button both trigger `switchBack()`.
struct ActAsBannerModifier: ViewModifier {
    @EnvironmentObject private var authService: AuthService

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if authService.actingPersonID != nil {
                    banner
                }
            }
    }

    private var actingName: String {
        authService.actorPerson?.name ?? ""
    }

    private var banner: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundColor(.white)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("profileswitch.banner.actingas", actingName as NSString))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text("profileswitch.banner.switchback")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button(action: { authService.switchBack() }) {
                Text("profileswitch.banner.button")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Capsule())
            }
            .accessibilityLabel(Text("profileswitch.banner.button.a11y"))
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        .frame(maxWidth: .infinity)
        .background(Color.dsPrimary)
        .contentShape(Rectangle())
        // Tap anywhere on the banner — not just the pill — switches back.
        .onTapGesture { authService.switchBack() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            L("profileswitch.banner.actingas", actingName as NSString)
                + ". "
                + L("profileswitch.banner.switchback")
        ))
        .accessibilityAddTraits(.isButton)
    }
}

extension View {
    func actAsBanner() -> some View {
        modifier(ActAsBannerModifier())
    }
}
