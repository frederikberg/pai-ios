import PAIKit
import SwiftUI
import UIKit

extension TodoColor.Pair {
    /// The pair as one colour that follows the light or dark appearance.
    var color: Color {
        let light = UIColor(todoHex: self.light)
        let dark = UIColor(todoHex: self.dark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension TodoColor {
    var swatch: Color { hue.swatch.color }
    var ink: Color { hue.ink.color }
    var chip: Color { hue.chip.color }
    var chipText: Color { hue.chipText.color }
}

extension UIColor {
    /// `#rrggbb` or `#rrggbbaa`; anything else is clear.
    convenience init(todoHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(digits, radix: 16) ?? 0
        let hasAlpha = digits.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        self.init(red: red, green: green, blue: blue, alpha: digits.count == 6 || hasAlpha ? alpha : 0)
    }
}

/// A todo's tick circle: its horizon's ring while open (dashed for Whenever, a dot for Now), a
/// filled circle with a check once done.
struct TodoTickCircle: View {
    let mark: TodoHorizonMark
    let done: Bool
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            if done {
                Circle().fill(PaiPalette.surface400)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .strokeBorder(
                        mark.color.swatch, style: StrokeStyle(lineWidth: 2, dash: mark.dashed ? [3, 3] : []))
                if mark.dot {
                    Circle().fill(mark.color.swatch).frame(width: size * 0.28, height: size * 0.28)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A tag as a chip in its colour.
struct TodoTagChip: View {
    let name: String
    let color: TodoColor

    var body: some View {
        Text(name)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color.chipText)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.chip))
    }
}

/// A view's, list's or tag's symbol in its colour.
struct TodoIdentityIcon: View {
    let identity: TodoIdentity
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: identity.icon.systemImage)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(identity.color.ink)
            .frame(width: size + 8)
    }
}
