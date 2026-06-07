import SwiftUI
import UIKit

/// The Dosely brand header — the pill-and-heart mark plus the "Dosely"
/// wordmark, sized for the top of a screen. Shown on the sign-in screen and
/// the client home.
///
/// The shipped art (`DoselyLogo`) is an opaque, white-background raster, so the
/// banner seats it on a fixed-white rounded badge rather than dropping it
/// straight onto the page: on a dark background a bare white-background image
/// reads as a glaring white rectangle. The badge is the logo's own substrate
/// made deliberate — it reads cleanly in light, dark, AND high contrast because
/// the hairline border (an adaptive DS token) carries the edge definition, not
/// the art. `dsSurface` is deliberately NOT used for the badge: it turns
/// charcoal in dark mode, which would reintroduce the white-rectangle problem.
///
/// Height tracks Dynamic Type via `@ScaledMetric` so the mark grows with the
/// user's text size — a raster `Image` doesn't scale on its own, and a header
/// that sits above body copy has to grow alongside it — clamped so the largest
/// accessibility sizes don't blow the bar out of proportion.
///
/// The whole thing is one accessibility element labeled "Dosely" (a brand
/// proper noun, identical in English and Punjabi, so it isn't localized), so
/// VoiceOver announces the brand once rather than reading it as an image.
///
/// `imageName` is injectable purely so the smoke test can exercise the
/// text-wordmark fallback (a deliberately-absent asset) without disturbing the
/// catalog entry.
struct DoselyBanner: View {
    var imageName: String = "DoselyLogo"

    /// ~64 pt at the default text size (≈2× the prior render); grows with
    /// Dynamic Type and is clamped at 96 pt so the header stays a header at the
    /// largest accessibility sizes instead of pushing content off the bottom.
    @ScaledMetric private var logoHeight: CGFloat = 64

    private var hasLogo: Bool { UIImage(named: imageName) != nil }

    var body: some View {
        Group {
            if hasLogo {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: min(logoHeight, 96))
            } else {
                // Asset missing (should not happen in a shipped build). Fall
                // back to an adaptive text wordmark so the banner never renders
                // empty; dsPrimary stands in for the teal mark.
                Text("Dosely")
                    .dsTitleLarge()
                    .foregroundColor(.dsPrimary)
            }
        }
        // Full-width brand card: inner padding gives the mark breathing room,
        // and the white substrate is applied to the WHOLE badge (not just
        // hugging the logo) so it reads as the screen's header rather than a
        // small centered ornament. White is the logo art's native substrate,
        // fixed in both appearances — see the DSColors "Sanctioned non-token
        // color usages" audit note (category 5).
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpacing.lg)
        .padding(.horizontal, DSSpacing.md)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: DSSpacing.rLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSSpacing.rLg, style: .continuous)
                .stroke(Color.dsTextSecondary.opacity(0.25), lineWidth: 1)
        )
        // Outer inset matches the dose-card column (horizontal lg) so the banner
        // aligns with the cards below it.
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dosely"))
        .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
#Preview("Banner · light") {
    DoselyBanner()
        .background(Color.dsBackground)
}

#Preview("Banner · dark") {
    DoselyBanner()
        .background(Color.dsBackground)
        .preferredColorScheme(.dark)
}

#Preview("Banner · fallback wordmark") {
    DoselyBanner(imageName: "DoselyLogo.__absent__")
        .background(Color.dsBackground)
}
#endif
