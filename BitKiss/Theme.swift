import SwiftUI

/// BitKiss colours, in one place.
enum BK {
    static let plum = Color(red: 0x1E/255, green: 0x12/255, blue: 0x30/255)
    static let card = Color.white.opacity(0.08)
    static let pink = Color(red: 0xFF/255, green: 0x5C/255, blue: 0x8A/255)
    static let orange = Color(red: 0xF7/255, green: 0x93/255, blue: 0x1A/255)
    static let green = Color(red: 0x78/255, green: 0xDC/255, blue: 0x8C/255)
    static let muted = Color.white.opacity(0.65)
}

/// Thousands separator for sats: 395316 -> "395,316".
func satsText(_ sats: UInt64) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    return f.string(from: NSNumber(value: sats)) ?? "\(sats)"
}
