import CoreGraphics

enum DSSpacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xxl: CGFloat = 48

    static let rSm: CGFloat = 8
    static let rMd: CGFloat = 12
    static let rLg: CGFloat = 16

    // WCAG 2.5.5 target size — B.1 U2. Floor for every tappable element.
    static let minTapTarget: CGFloat = 48
}
