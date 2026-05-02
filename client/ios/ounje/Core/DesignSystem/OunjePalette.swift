import SwiftUI
import Foundation

enum OunjePalette {
    static let background = Color(hex: "121212")
    static let panel = Color(hex: "1E1E1E")
    static let surface = Color(hex: "2E2E2E")
    static let elevated = Color(hex: "383838")
    static let navBar = Color(hex: "1B1D20")
    static let accent = Color(hex: "1E5A3E")
    static let accentDark = Color(hex: "123828")
    static let softCream = Color(hex: "E9E0D2")
    static let tabSelected = Color(hex: "2D6B4B")
    static let secondaryText = Color(hex: "8A8A8A")
    static let linkText = Color(hex: "B2FFFF")
    static let stroke = Color.white.opacity(0.08)
    static let primaryText = Color.white
}

extension Color {
    init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: cleaned)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
