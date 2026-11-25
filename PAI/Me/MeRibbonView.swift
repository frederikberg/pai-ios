import PAIKit
import SwiftUI

/// One day on a 00:00 to 24:00 axis: four lanes (body, plans, you, done), the diary's faces above
/// them, hour marks and the 22:00 line below, and the current time for today. A lane without data
/// is an empty track. Drawn in one canvas; the caller supplies the moment so the line moves once
/// a minute and nothing animates.
struct MeRibbonView: View {
    let ribbon: MeRibbon
    @Environment(\.colorScheme) private var scheme

    private let gutter: CGFloat = 36
    private let laneTops: [CGFloat] = [16, 29, 42, 55]
    private let laneNames = ["body", "plans", "you", "done"]
    private let laneHeight: CGFloat = 9

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Canvas { context, size in draw(context, size) }
            .frame(height: 86)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Day ribbon")
            .accessibilityValue(summary)
            .accessibilityIdentifier("me-ribbon")
    }

    /// What the ribbon holds, in words, for VoiceOver.
    private var summary: String {
        var parts: [String] = []
        if ribbon.sleep != nil { parts.append("sleep") }
        if !ribbon.activities.isEmpty { parts.append("\(ribbon.activities.count) activities") }
        if !ribbon.plans.isEmpty { parts.append("\(ribbon.plans.count) appointments") }
        if !ribbon.you.isEmpty { parts.append("messages written") }
        if !ribbon.done.isEmpty { parts.append("\(ribbon.done.count) tasks ticked") }
        return parts.joined(separator: ", ")
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let track = size.width - gutter
        func x(_ minute: Double) -> CGFloat { gutter + CGFloat(minute / MeRibbon.minutesPerDay) * track }
        func label(_ string: String, at point: CGPoint, anchor: UnitPoint, color: Color, weight: Font.Weight = .regular)
        {
            let text = Text(string).font(.system(size: 10, weight: weight)).foregroundStyle(color)
            context.draw(context.resolve(text), at: point, anchor: anchor)
        }
        func block(_ span: MeSpan, top: CGFloat, color: Color) {
            let left = x(span.start)
            let width = max(3, x(span.end) - left)
            let rect = CGRect(x: min(left, size.width - width), y: top, width: width, height: laneHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
        }

        let guide = PaiPalette.Semantic.borderDefault
        for hour in MePresenter.ribbonHours(width: Double(size.width)) {
            let at = x(Double(hour * 60))
            context.fill(Path(CGRect(x: at, y: 14, width: 1, height: 54)), with: .color(guide))
            label(
                "\(hour)", at: CGPoint(x: at, y: 78), anchor: .center, color: PaiPalette.Semantic.textMuted)
        }
        for (index, top) in laneTops.enumerated() {
            let rect = CGRect(x: gutter, y: top, width: track, height: laneHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(PaiPalette.Semantic.insetBackground))
            label(
                laneNames[index], at: CGPoint(x: gutter - 6, y: top + laneHeight / 2), anchor: .trailing,
                color: PaiPalette.Semantic.textMuted)
        }

        if let sleep = ribbon.sleep { block(sleep, top: laneTops[0], color: MeColor.sleep.opacity(0.4)) }
        for span in ribbon.activities { block(span, top: laneTops[0], color: MeColor.movement(dark: dark)) }
        for span in ribbon.plans { block(span, top: laneTops[1], color: MeColor.calendar.opacity(0.75)) }
        for span in ribbon.you { block(span, top: laneTops[2], color: MeColor.you.opacity(0.85)) }
        for minute in ribbon.done {
            let rect = CGRect(x: x(minute) - 1.25, y: laneTops[3], width: 2.5, height: laneHeight)
            context.fill(Path(rect), with: .color(MeColor.done))
        }

        // The 22:00 line: the day's end for him, a mark and never a countdown.
        var evening = Path()
        evening.move(to: CGPoint(x: x(22 * 60), y: 14))
        evening.addLine(to: CGPoint(x: x(22 * 60), y: 68))
        context.stroke(evening, with: .color(PaiPalette.surface600), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        label("22", at: CGPoint(x: x(22 * 60), y: 78), anchor: .center, color: PaiPalette.Semantic.textSecondary)

        let nowX = ribbon.now.map(x)
        for dot in ribbon.diary {
            let at = x(dot.minute)
            // A face near the "now" label moves below its line.
            let centerY: CGFloat = nowX.map { abs($0 - at) < 14 } == true ? 12 : 7
            let rect = CGRect(x: at - 4, y: centerY - 4, width: 8, height: 8)
            if let feel = dot.feel {
                context.fill(Path(ellipseIn: rect), with: .color(MeColor.feel(feel, dark: dark)))
            } else if dot.isPrivate {
                context.fill(Path(ellipseIn: rect), with: .color(MeColor.lock(dark: dark)))
            } else {
                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(PaiPalette.surface500), lineWidth: 1)
            }
        }

        if let nowX, let minute = ribbon.now {
            var line = Path()
            line.move(to: CGPoint(x: nowX, y: 12))
            line.addLine(to: CGPoint(x: nowX, y: 70))
            context.stroke(line, with: .color(PaiPalette.primary400), lineWidth: 1.5)
            let whole = Int(minute)
            let time = String(format: "%02d:%02d", whole / 60, whole % 60)
            let text = context.resolve(
                Text(time).font(.system(size: 10, weight: .semibold)).foregroundStyle(PaiPalette.primary400))
            let measured = text.measure(in: CGSize(width: 80, height: 14))
            let center = min(max(nowX, measured.width / 2 + 3), size.width - measured.width / 2 - 3)
            let backing = CGRect(x: center - measured.width / 2 - 3, y: -1, width: measured.width + 6, height: 12)
            context.fill(Path(roundedRect: backing, cornerRadius: 3), with: .color(PaiPalette.Semantic.raisedSurface))
            context.draw(text, at: CGPoint(x: center, y: 5), anchor: .center)
        }
    }
}
