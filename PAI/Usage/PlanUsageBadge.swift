import PAIKit
import SwiftUI

/// The account's plan usage: `⏳ 55%/26% 18:20` — the five-hour window, the seven-day window, and
/// when the five-hour one resets, each window coloured by its own pace. Swift port of
/// `UsageBadge.tsx`, and the same three figures the statusline shows; renders nothing until the agent has reported (the caller already guards on
/// `usage` being non-nil, so this only ever formats real data).
///
/// All three earn their place for different reasons. The five-hour figure is the one that moves
/// while the user works. The reset time is what decides whether to start something now or wait —
/// the web keeps it even on its narrowest layout for that reason. The seven-day figure moves
/// slowly but is the one that ends a week early when it runs out, and a percentage with no window
/// named beside it is ambiguous about which of the two it is.
struct PlanUsageBadge: View {
    let usage: Usage

    var body: some View {
        if usage.fiveHour != nil || usage.sevenDay != nil {
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .foregroundStyle(PaiPalette.surface500)
                HStack(spacing: 0) {
                    Text(percent(usage.fiveHour)).foregroundStyle(color(usage.fiveHour))
                    Text("/").foregroundStyle(color(usage.sevenDay))
                    Text(percent(usage.sevenDay)).foregroundStyle(color(usage.sevenDay))
                }
                if let resetsAt {
                    Text(resetsAt).foregroundStyle(PaiPalette.surface500)
                }
            }
            .monospacedDigit()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("plan-usage-badge")
        }
    }

    private func percent(_ window: UsageWindow?) -> String {
        guard let window else { return "–" }
        return "\(Int(window.utilization.rounded()))%"
    }

    /// 🚨 Through `IsoTimestamp`, never a bare `ISO8601DateFormatter` — this field arrives with
    /// six fractional digits and a numeric offset, which the default parser rejects outright.
    /// That rejection is a `nil`, indistinguishable here from the server never having sent a
    /// reset time, which is exactly why nothing reported it while the time was simply missing.
    private var resetsAt: String? {
        guard let iso = usage.fiveHour?.resetsAt, let date = IsoTimestamp.date(from: iso) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var accessibilityLabel: String {
        var parts = [
            "\(percent(usage.fiveHour)) of the 5-hour window\(paceSuffix(usage.fiveHour))",
            "\(percent(usage.sevenDay)) of the 7-day window\(paceSuffix(usage.sevenDay))",
        ]
        if let resetsAt { parts.append("5-hour window resets at \(resetsAt)") }
        return parts.joined(separator: ", ")
    }

    private func paceSuffix(_ window: UsageWindow?) -> String {
        window?.paceDescription.map { " (\($0))" } ?? ""
    }

    private func color(_ window: UsageWindow?) -> Color {
        (window?.paceTone ?? .neutral).color
    }
}
