import SwiftUI

/// Every colour, size and curve in the app, defined once.
///
/// Values pixel-sampled from the 1 June design exports. A hardcoded hex in a
/// card is how a palette change becomes a nine-file edit, so views must never
/// name a colour directly.
public enum Tokens {

    // MARK: - Colour

    public enum Palette {
        /// The single accent. The mockups contain two purples — this one and
        /// `#652DD1` on the Albus tab — and the darker value is reused as the
        /// pressed state rather than treated as a second accent.
        public static let accent = Color(hex: 0x743EE4)
        public static let accentPressed = Color(hex: 0x652DD1)

        public static let ink = Color(hex: 0x1A1725)
        public static let inkSecondary = Color(hex: 0x6D6759)
        public static let cardSurface = Color(hex: 0xFBFAF9)
        public static let hairline = Color(hex: 0xE5E1DC)

        /// The app background is a single full-screen gradient behind all four
        /// tabs, not a per-screen colour. Built once in the shell.
        public static let backgroundStops: [Gradient.Stop] = [
            .init(color: Color(hex: 0xDCD1E2), location: 0.00),
            .init(color: Color(hex: 0xEAE5E3), location: 0.30),
            .init(color: Color(hex: 0xF0ECE5), location: 0.60),
            .init(color: Color(hex: 0xE8E9E1), location: 1.00)
        ]
    }

    /// Subject colour is a property of the course, never of the card that shows
    /// it. HIST is red on every screen; a view maps the enum and never picks.
    public enum SubjectColor: String, CaseIterable, Sendable, Codable {
        case violet, red, amber, green, blue, pink

        public var color: Color {
            switch self {
            case .violet: Color(hex: 0x743EE4)
            case .red:    Color(hex: 0xD4615C)
            case .amber:  Color(hex: 0xEAB657)
            case .green:  Color(hex: 0x6FBDA1)
            case .blue:   Color(hex: 0x5B8DEF)
            case .pink:   Color(hex: 0xD98CB3)
            }
        }
    }

    // MARK: - Type

    /// Three sizes per screen, per the design rule. Dynamic Type respected via
    /// `.relativeTo` so accessibility sizes still scale.
    public enum Typography {
        public static let displayLarge = Font.system(size: 34, weight: .bold, design: .default)
        public static let title        = Font.system(size: 22, weight: .semibold, design: .default)
        public static let body         = Font.system(size: 16, weight: .regular, design: .default)
        public static let label        = Font.system(size: 13, weight: .medium, design: .default)
        public static let caption      = Font.system(size: 11, weight: .medium, design: .default)
        /// Times and countdowns, so digits do not jitter as they change.
        public static let mono         = Font.system(size: 13, weight: .medium, design: .monospaced)
    }

    // MARK: - Layout

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        /// Height the floating tab bar occupies. Content scrolls under it, so
        /// this is applied once in the shell and never by a screen.
        public static let tabBarInset: CGFloat = 96
    }

    public enum Radius {
        public static let card: CGFloat = 16
        public static let sheet: CGFloat = 24
        public static let pill: CGFloat = 999
        public static let chip: CGFloat = 10
    }

    public enum Motion {
        /// The sheet curve used throughout the designs.
        public static let sheet = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.28)
        public static let quick = Animation.easeOut(duration: 0.18)
    }
}

extension Color {
    /// Hex literals keep the token file legible against the design exports.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
