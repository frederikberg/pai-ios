import Foundation

/// One of the two rows the Weather screen shows.
public struct WeatherRow: Equatable, Sendable {
    public let verdict: RainVerdict
    /// The big part: "70 %", "dry all day", or a dash when there is no answer.
    public let value: String
    /// What follows the value on the same line: "from 15:20".
    public let detail: String?
    /// The calm sentence below: "showers 8 km W, closing in".
    public let caption: String?
}

/// One bar of the 12-hour strip: its height is the chance, its colour the intensity, and every
/// third bar carries the hour it starts as a label.
public struct WeatherStripBar: Equatable, Sendable, Identifiable {
    public let id: String
    public let chance: Int
    public let intensity: RainIntensity
    public let label: String?
}

/// Turns the server's answer into the words on the Weather screen. Times are the server's UTC
/// instants shown in `calendar`'s time zone on a 24-hour clock.
public struct WeatherPresenter: Sendable {
    public let now: Date
    public let calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    /// "Rain pants now?": the next hour.
    public func nowRow(_ now: WeatherNow) -> WeatherRow {
        if let missing = missingAnswer(verdict: now.verdict, reason: now.reason) {
            return WeatherRow(verdict: .unknown, value: "–", detail: nil, caption: missing)
        }
        let value = now.chance.map(percent) ?? verdictWord(now.verdict)
        var detail: String?
        if !now.rainingNow, let start = now.startDate { detail = "from \(clock(start))" }
        return WeatherRow(verdict: now.verdict, value: value, detail: detail, caption: nowCaption(now))
    }

    /// "Pack them?": the next twelve hours.
    public func laterRow(_ later: WeatherLater) -> WeatherRow {
        if let missing = missingAnswer(verdict: later.verdict, reason: later.reason) {
            return WeatherRow(verdict: .unknown, value: "–", detail: nil, caption: missing)
        }
        if later.verdict == .dry {
            return WeatherRow(verdict: .dry, value: "dry all day", detail: nil, caption: nil)
        }
        let value = later.chance.map(percent) ?? verdictWord(later.verdict)
        let detail = later.atDate.map { "from ~\(dayClock($0))" }
        // The headline chance can belong to a later hour than the start, so the caption names
        // when the rain is heaviest and how much falls.
        var parts: [String] = []
        if let heaviest = later.heaviestDate { parts.append("heaviest ~\(dayClock(heaviest))") }
        if let total = later.totalMm, total >= 0.1 { parts.append("about \(millimetres(total)) in total") }
        if later.method == "forecast" { parts.append("from the forecast, no radar here") }
        let caption = parts.isEmpty ? nil : parts.joined(separator: " · ")
        return WeatherRow(verdict: later.verdict, value: value, detail: detail, caption: caption)
    }

    /// The 12 hours as bars; empty when the answer has none or there is no answer.
    public func strip(_ later: WeatherLater) -> [WeatherStripBar] {
        guard later.verdict != .unknown else { return [] }
        return later.hours.enumerated().map { index, hour in
            let label = index % 3 == 0 ? hour.startDate.map { hourOfDay($0) } : nil
            return WeatherStripBar(id: hour.start, chance: hour.chance, intensity: hour.intensity, label: label)
        }
    }

    /// An amount of rain as people say it: whole millimetres from 2 up, one decimal below.
    public func millimetres(_ amount: Double) -> String {
        amount >= 2 ? "\(Int(amount.rounded())) mm" : String(format: "%.1f mm", amount)
    }

    /// "Aachen · 5 min ago · Radar: DWD · Forecast: Open-Meteo"; just the attribution when no
    /// location is stored.
    public func footer(_ weather: WeatherResponse) -> String {
        var parts: [String] = []
        if let location = weather.location {
            if let place = location.place, !place.isEmpty { parts.append(place) }
            if let recorded = location.recordedDate { parts.append(age(of: recorded)) }
        }
        parts.append(weather.attribution)
        return parts.joined(separator: " · ")
    }

    /// How long ago a moment was, in the coarsest unit that is honest.
    public func age(of date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<3600: return "\(Int((seconds / 60).rounded())) min ago"
        case ..<86400: return "\(Int((seconds / 3600).rounded())) h ago"
        default: return "\(Int((seconds / 86400).rounded())) d ago"
        }
    }

    // MARK: Pieces

    private func missingAnswer(verdict: RainVerdict, reason: WeatherUnknownReason?) -> String? {
        switch reason {
        case .noLocation: return "Pick your iPhone in Settings → Location"
        case .sourceUnavailable: return "The weather sources are not answering right now"
        case .unrecognized, nil: return verdict == .unknown ? "No answer yet" : nil
        }
    }

    private func nowCaption(_ now: WeatherNow) -> String? {
        if now.rainingNow {
            guard let end = now.endDate else { return "raining now" }
            return "raining now · until \(clock(end))"
        }
        switch now.verdict {
        case .rain, .maybe, .unlikely:
            if let km = now.nearestKm {
                var text = "showers \(distance(km))"
                if let direction = now.direction { text += " \(direction.label)" }
                if let trend = now.trend, let suffix = trendSuffix(trend) { text += ", \(suffix)" }
                return text
            }
            return now.method == "forecast" ? "from the forecast, no radar here" : nil
        case .dry:
            return now.method == "forecast" ? "dry in the forecast, no radar here" : "dry around you"
        case .unknown, .unrecognized:
            return nil
        }
    }

    private func trendSuffix(_ trend: RainTrend) -> String? {
        switch trend {
        case .approaching: return "closing in"
        case .passing: return "passing"
        case .leaving: return "moving away"
        case .unrecognized: return nil
        }
    }

    private func verdictWord(_ verdict: RainVerdict) -> String {
        switch verdict {
        case .rain: return "rain"
        case .maybe: return "maybe"
        case .unlikely: return "unlikely"
        case .dry: return "dry"
        case .unknown, .unrecognized: return "–"
        }
    }

    private func percent(_ chance: Int) -> String { "\(chance) %" }

    private func distance(_ km: Double) -> String {
        km < 1 ? "under 1 km" : "\(Int(km.rounded())) km"
    }

    private func clock(_ date: Date) -> String { ClockTime.string(date, calendar: calendar) }

    private func hourOfDay(_ date: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        return hour < 10 ? "0\(hour)" : "\(hour)"
    }

    /// The clock time, prefixed with "tomorrow" when it falls on another day than now.
    private func dayClock(_ date: Date) -> String {
        calendar.isDate(date, inSameDayAs: now) ? clock(date) : "tomorrow \(clock(date))"
    }
}
