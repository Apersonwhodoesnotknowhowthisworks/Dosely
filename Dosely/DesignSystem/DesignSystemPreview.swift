import SwiftUI

struct DesignSystemPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                colorsSection
                typographySection
                spacingSection
                buttonsSection
            }
            .padding(DSSpacing.lg)
        }
        .background(Color.dsBackground.ignoresSafeArea())
    }

    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Colors").dsTitleMedium().foregroundColor(.dsTextPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: DSSpacing.md)],
                      spacing: DSSpacing.md) {
                swatch("dsPrimary",       .dsPrimary,       textColor: .white)
                swatch("dsSuccess",       .dsSuccess,       textColor: .white)
                swatch("dsWarning",       .dsWarning,       textColor: .white)
                swatch("dsDanger",        .dsDanger,        textColor: .white)
                swatch("dsBackground",    .dsBackground,    textColor: .dsTextPrimary)
                swatch("dsSurface",       .dsSurface,       textColor: .dsTextPrimary)
                swatch("dsTextPrimary",   .dsTextPrimary,   textColor: .white)
                swatch("dsTextSecondary", .dsTextSecondary, textColor: .white)
            }
        }
    }

    private func swatch(_ name: String, _ color: Color, textColor: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DSSpacing.rMd)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: DSSpacing.rMd)
                        .stroke(Color.dsTextSecondary.opacity(0.2), lineWidth: 1)
                )
            Text(name)
                .dsCaption()
                .foregroundColor(textColor)
        }
        .frame(height: 72)
    }

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Typography").dsTitleMedium().foregroundColor(.dsTextPrimary)
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text("titleLarge — Good morning").dsTitleLarge().foregroundColor(.dsTextPrimary)
                Text("titleMedium — Your medications").dsTitleMedium().foregroundColor(.dsTextPrimary)
                Text("bodyLarge — Take one tablet with food at 8:00 AM.").dsBodyLarge().foregroundColor(.dsTextPrimary)
                Text("bodyRegular — Secondary body copy.").dsBodyRegular().foregroundColor(.dsTextSecondary)
                Text("caption — Last taken 2h ago").dsCaption().foregroundColor(.dsTextSecondary)
            }
            .padding(DSSpacing.md)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
        }
    }

    private var spacingSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Spacing").dsTitleMedium().foregroundColor(.dsTextPrimary)
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                spacingBar("xs  · 4",   DSSpacing.xs)
                spacingBar("sm  · 8",   DSSpacing.sm)
                spacingBar("md  · 16",  DSSpacing.md)
                spacingBar("lg  · 24",  DSSpacing.lg)
                spacingBar("xl  · 32",  DSSpacing.xl)
                spacingBar("xxl · 48",  DSSpacing.xxl)
            }
            .padding(DSSpacing.md)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
        }
    }

    private func spacingBar(_ label: String, _ width: CGFloat) -> some View {
        HStack(spacing: DSSpacing.md) {
            Text(label)
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .frame(width: 90, alignment: .leading)
            Rectangle()
                .fill(Color.dsPrimary)
                .frame(width: width, height: 16)
                .cornerRadius(DSSpacing.rSm)
            Spacer()
        }
    }

    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Buttons").dsTitleMedium().foregroundColor(.dsTextPrimary)
            VStack(spacing: DSSpacing.md) {
                sampleButton("Primary · Take dose",   background: .dsPrimary,  foreground: .white)
                sampleButton("Success · Logged",      background: .dsSuccess,  foreground: .white)
                sampleButton("Warning · Refill soon", background: .dsWarning,  foreground: .white)
                sampleButton("Danger · Missed dose",  background: .dsDanger,   foreground: .white)
            }

            HStack(spacing: DSSpacing.sm) {
                compactButton("sm gap")
                compactButton("sm gap")
                compactButton("sm gap")
            }
            HStack(spacing: DSSpacing.md) {
                compactButton("md gap")
                compactButton("md gap")
            }
            HStack(spacing: DSSpacing.lg) {
                compactButton("lg gap")
                compactButton("lg gap")
            }
        }
    }

    private func sampleButton(_ title: String, background: Color, foreground: Color) -> some View {
        Button(action: {}) {
            Text(title)
                .dsBodyLarge()
                .foregroundColor(foreground)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                .background(background)
                .cornerRadius(DSSpacing.rMd)
        }
    }

    private func compactButton(_ title: String) -> some View {
        Button(action: {}) {
            Text(title)
                .dsBodyRegular()
                .foregroundColor(.dsPrimary)
                .padding(.horizontal, DSSpacing.md)
                .frame(minWidth: DSSpacing.minTapTarget, minHeight: DSSpacing.minTapTarget)
                .background(Color.dsSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: DSSpacing.rMd)
                        .stroke(Color.dsPrimary, lineWidth: 1.5)
                )
                .cornerRadius(DSSpacing.rMd)
        }
    }
}

#Preview("Design System") {
    DesignSystemPreview()
}

#Preview("Design System · XXL type") {
    DesignSystemPreview()
        .environment(\.dynamicTypeSize, .accessibility3)
}
