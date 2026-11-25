import Foundation

/// The "Where" line of a day: the places he stayed, in order, and how far he moved.
public struct LocationDayLine: Equatable, Sendable {
    /// `Home –08:10 · Work 08:40–17:20 · Aachen 18:00–19:30 · Home 19:50– · 14.2 km`
    public let text: String
    /// True when the history has a gap over six hours between two different places.
    public let hasGaps: Bool
}

extension MePresenter {

    /// The line for one day, nil when the history holds nothing for it. A stay that began before the
    /// day starts reads `–08:10` and one that runs past its end reads `19:50–`; the rest read
    /// `from–to`. A stay without a named place or a locality reads `Somewhere`.
    public func locationLine(_ day: LocationDay) -> LocationDayLine? {
        guard day.coverage != .none, let start = date(forKey: day.date),
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        var parts: [String] = []
        for stay in day.stays {
            guard let from = IsoTimestamp.date(from: stay.from), let to = IsoTimestamp.date(from: stay.to) else {
                continue
            }
            let name = stay.place ?? stay.locality ?? "Somewhere"
            let opening = from < start ? "" : clock(from)
            let closing = to >= end ? "" : clock(to)
            parts.append("\(name) \(opening)–\(closing)")
        }
        if let km = day.movedKm, km >= 0.1 { parts.append(String(format: "%.1f km", km)) }
        guard !parts.isEmpty else { return nil }
        return LocationDayLine(text: parts.joined(separator: " · "), hasGaps: day.coverage == .partial)
    }
}
