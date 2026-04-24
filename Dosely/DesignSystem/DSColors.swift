import SwiftUI

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    static let dsPrimary       = Color(hex: 0x2B6CB0)
    static let dsSuccess       = Color(hex: 0x2F855A)
    static let dsWarning       = Color(hex: 0xD69E2E)
    static let dsDanger        = Color(hex: 0xC53030)
    static let dsBackground    = Color(hex: 0xF7FAFC)
    static let dsSurface       = Color.white
    static let dsTextPrimary   = Color(hex: 0x1A202C)
    static let dsTextSecondary = Color(hex: 0x4A5568)
}
