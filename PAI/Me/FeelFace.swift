import PAIKit
import SwiftUI

/// The colours of the Me screens. A colour says what a row is, never how good a day was; the only
/// value-coloured thing is the face the person picked.
enum MeColor {
    static func feel(_ feel: SelfReportFeel, dark: Bool) -> Color {
        switch feel {
        case .good: dark ? PaiPalette.amber400 : PaiPalette.amber500
        case .okay, .unrecognized: dark ? PaiPalette.surface400 : PaiPalette.surface500
        case .heavy: dark ? PaiPalette.primary400 : PaiPalette.primary500
        }
    }

    static func lock(dark: Bool) -> Color { dark ? PaiPalette.assistant400 : PaiPalette.assistant500 }
    static let sleep = PaiPalette.primary500
    static let battery = PaiPalette.relay500
    /// The sleep score's line and numbers: Tailwind's sky-500, the web's tone for them.
    static let sleepScore = Color(red: 0.055, green: 0.647, blue: 0.914)
    static func movement(dark: Bool) -> Color { dark ? PaiPalette.orange400 : PaiPalette.orange500 }
    static func pai(dark: Bool) -> Color { dark ? PaiPalette.surface500 : PaiPalette.surface400 }
    /// Calendar appointments: Tailwind's sky-400, the web's calendar tone.
    static let calendar = Color(red: 0.220, green: 0.741, blue: 0.973)
    /// The person's own messages on the ribbon.
    static let you = PaiPalette.surface400
    static let done = PaiPalette.relay500

    /// The colour a day-detail fact line carries.
    static func fact(_ tone: MeFactTone, dark: Bool) -> Color {
        switch tone {
        case .sleep: sleep
        case .movement: movement(dark: dark)
        case .calendar: calendar
        case .ambient, .agents, .morning: PaiPalette.surface500
        case .you: you
        case .done: done
        }
    }
}

/// A drawn face, not an emoji, so it looks the same on every device and takes the tint. A circle
/// in a 22-unit box, two eyes, a mouth that is a smile, a line or a frown.
struct FeelFace: View {
    let feel: SelfReportFeel
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = MeColor.feel(feel, dark: scheme == .dark)
        Canvas { context, canvasSize in
            let unit = canvasSize.width / 22
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            let circle = Path(
                ellipseIn: CGRect(x: 1 * unit, y: 1 * unit, width: 20 * unit, height: 20 * unit))
            context.fill(circle, with: .color(color.opacity(0.16)))
            context.stroke(circle, with: .color(color), lineWidth: 1.6 * unit)
            for x in [8.0, 14.0] {
                let eye = Path(
                    ellipseIn: CGRect(x: (x - 1.25) * unit, y: (9 - 1.25) * unit, width: 2.5 * unit, height: 2.5 * unit)
                )
                context.fill(eye, with: .color(color))
            }
            var mouth = Path()
            switch feel {
            case .good:
                mouth.move(to: point(7, 13))
                mouth.addQuadCurve(to: point(15, 13), control: point(11, 17.2))
            case .okay, .unrecognized:
                mouth.move(to: point(7.5, 14.3))
                mouth.addLine(to: point(14.5, 14.3))
            case .heavy:
                mouth.move(to: point(7, 15.6))
                mouth.addQuadCurve(to: point(15, 15.6), control: point(11, 12))
            }
            context.stroke(
                mouth, with: .color(color),
                style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension SelfReportFeel {
    /// The word VoiceOver and the filter chips use.
    var spokenName: String {
        switch self {
        case .good: "Good"
        case .okay: "Okay"
        case .heavy: "Heavy"
        case .unrecognized: "Other"
        }
    }
}
