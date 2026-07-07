import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }

    static let rBackground = Color(hex: 0x0A0B10)
    static let rSurface = Color(hex: 0x141824)
    static let rBorder = Color(hex: 0x232B3D)
    static let rLime = Color(hex: 0xC8FF00)
    static let rTeal = Color(hex: 0x3DF5C6)
    static let rPurple = Color(hex: 0xB48CFF)
    static let rOrange = Color(hex: 0xFF7A3D)
    static let rTextSecondary = Color(hex: 0x8A8F9E)
}

enum ActivityType: String, Codable, CaseIterable, Sendable {
    case run, walk, bike

    var emoji: String {
        switch self {
        case .run: "🏃"
        case .walk: "🚶"
        case .bike: "🚴"
        }
    }

    var accent: Color {
        switch self {
        case .run: .rTeal
        case .walk: .rLime
        case .bike: .rPurple
        }
    }

    var localizedName: String {
        switch self {
        case .run: String(localized: "Run")
        case .walk: String(localized: "Walk")
        case .bike: String(localized: "Bike")
        }
    }
}

struct GlowShadow: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.55), radius: 12)
            .shadow(color: color.opacity(0.25), radius: 28)
    }
}
