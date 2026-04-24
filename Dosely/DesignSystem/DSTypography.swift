import SwiftUI

enum DSTypography {
    static let titleLarge   = Font.largeTitle.bold()
    static let titleMedium  = Font.title2.weight(.semibold)
    static let bodyLarge    = Font.system(size: 18, weight: .regular, design: .default)
    static let bodyRegular  = Font.body
    static let caption      = Font.caption
}

extension View {
    func dsTitleLarge() -> some View {
        self.font(DSTypography.titleLarge)
            .dynamicTypeSize(.large ... .accessibility5)
    }

    func dsTitleMedium() -> some View {
        self.font(DSTypography.titleMedium)
            .dynamicTypeSize(.large ... .accessibility5)
    }

    // Body text floor of 18pt — the elderly-user baseline (B.1 U1).
    // Uses a fixed-size font so the 18pt minimum holds, then re-enables
    // Dynamic Type scaling from .large upward.
    func dsBodyLarge() -> some View {
        self.font(DSTypography.bodyLarge)
            .dynamicTypeSize(.large ... .accessibility5)
    }

    func dsBodyRegular() -> some View {
        self.font(DSTypography.bodyRegular)
            .dynamicTypeSize(.large ... .accessibility5)
    }

    func dsCaption() -> some View {
        self.font(DSTypography.caption)
            .dynamicTypeSize(.large ... .accessibility5)
    }
}
