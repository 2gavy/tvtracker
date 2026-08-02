import SwiftUI

enum AppTheme {
    static let accent = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 1, green: 0.82, blue: 0.06, alpha: 1)
        }
        return UIColor(red: 0.55, green: 0.40, blue: 0, alpha: 1)
    })
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let elevated = Color(uiColor: .tertiarySystemBackground)
    static let separator = Color(uiColor: .separator)
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
