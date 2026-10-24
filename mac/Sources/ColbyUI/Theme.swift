// Design tokens (docs/design/tokens.json) for SwiftUI. Dark only.
#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import CoreText
import SwiftUI

public enum Theme {
    public enum Palette {
        public static let window = Color(hex: 0x000000)
        public static let card = Color(hex: 0x161616)
        public static let raised = Color(hex: 0x1F1F1F)
        public static let line = Color(hex: 0x2C2C2C)
        public static let grid = Color(hex: 0x2A2A2A)
        public static let text = Color(hex: 0xF5F5F5)
        public static let text2 = Color(hex: 0xC7C7C7)
        public static let muted = Color(hex: 0x9B9B9B)
        public static let disabled = Color(hex: 0x6B6B6B)
        public static let targetLine = Color(hex: 0xD9D9D9)
        public static let core = Color(hex: 0x4EA1F7)
        public static let surface = Color(hex: 0xFFB81C)
        public static let ambient = Color(hex: 0xF5701F)
        public static let otherSensor = Color(hex: 0x6B6B6B)
        public static let pillText = Color(hex: 0x000000)
        public static let ready = Color(hex: 0x5FD17A)
        public static let critical = Color(hex: 0xE5484D)
        public static let criticalBg = Color(hex: 0x3A1214)
        public static let criticalText = Color(hex: 0xFFD6D7)
        public static let warning = Color(hex: 0xFAB219)
        public static let warningBg = Color(hex: 0x2A2414)
        public static let badgeFill = Color(hex: 0x2A2A2A)
        public static let ringYellow = Color(hex: 0xE9C440)
        public static let ringGrey = Color(hex: 0xA3A3A3)
        public static let primaryBg = Color(hex: 0xF5F5F5)
        public static let primaryText = Color(hex: 0x000000)
    }

    public enum Radius {
        public static let control: CGFloat = 10
        public static let chip: CGFloat = 16
        public static let card: CGFloat = 28
    }

    /// Barlow for text, Barlow Condensed (tabular figures) for numbers. Falls back to the system font if the
    /// bundled files failed to register.
    public enum Fonts {
        public static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            let name = switch weight {
            case .bold, .heavy, .black: "Barlow-Bold"
            case .semibold: "Barlow-SemiBold"
            case .medium: "Barlow-Medium"
            default: "Barlow-Regular"
            }
            return registered ? .custom(name, fixedSize: size) : .system(size: size, weight: weight)
        }

        public static func numeric(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
            let name = weight == .semibold || weight == .bold ? "BarlowCondensed-SemiBold" : "BarlowCondensed-Medium"
            let base: Font = registered ? .custom(name, fixedSize: size) : .system(size: size, weight: weight)
            return base.monospacedDigit()
        }

        public static let caption = text(13)
        public static let body = text(15)
        public static let label = text(14, .semibold)
        public static let title = text(22, .bold)
        public static let header = text(32, .bold)
        public static let axis = numeric(16)
        public static let chipValue = numeric(30)
        public static let readout = numeric(72)
        public static let countdown = numeric(64, .semibold)
        public static let secondaryTime = numeric(22)

        /// Registers the bundled fonts for this process. Idempotent; call once at launch.
        @discardableResult
        public static func register() -> Bool {
            registered
        }

        private static let registered: Bool = {
            guard let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts"),
                  !urls.isEmpty else { return false }
            var ok = true
            for url in urls {
                var error: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    // Already registered counts as success (e.g. a second window scene).
                    let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
                    if code != CTFontManagerError.alreadyRegistered.rawValue { ok = false }
                }
            }
            return ok
        }()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
#endif
