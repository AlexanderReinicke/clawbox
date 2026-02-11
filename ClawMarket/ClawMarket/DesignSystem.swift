import SwiftUI
import AppKit

enum ClawDesignSystem {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
    }

    enum Typography {
        static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }
}

extension Color {
    static let shellDeepest = adaptive(light: 0xF6F8FC, dark: 0x0B0E14)
    static let shellSurface = adaptive(light: 0xFFFFFF, dark: 0x131720)
    static let shellElevated = adaptive(light: 0xEEF2F8, dark: 0x1A1F2E)
    static let shellBorder = adaptive(light: 0xD0D7E2, dark: 0x21262D)
    static let shellAccent = adaptive(light: 0x2D6CDF, dark: 0x58A6FF)
    static let shellAccentMuted = adaptive(light: 0xDCEBFF, dark: 0x1F3A5C)
    static let shellRunning = adaptive(light: 0x1F883D, dark: 0x3FB950)
    static let shellWarning = adaptive(light: 0x9A6700, dark: 0xD29922)
    static let shellError = adaptive(light: 0xCF222E, dark: 0xF85149)
    static let shellStopped = adaptive(light: 0x6E7781, dark: 0x484F58)
    static let shellTextPrimary = adaptive(light: 0x1F2328, dark: 0xE6EDF3)
    static let shellTextSecondary = adaptive(light: 0x57606A, dark: 0x8B949E)
    static let shellTextMuted = adaptive(light: 0x6E7781, dark: 0x484F58)
    static let shellScrim = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0.28)

    private static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1.0,
        darkAlpha: CGFloat = 1.0
    ) -> Color {
        Color(
            NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
                let useDark = match == .darkAqua || match == .vibrantDark
                return NSColor(
                    hex: useDark ? dark : light,
                    alpha: useDark ? darkAlpha : lightAlpha
                )
            }
        )
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
