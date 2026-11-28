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

/// The sky over the next 12 hours beside the temperature now and the span it moves in.
public struct WeatherSummary: Equatable, Sendable {
    public let symbol: WeatherSymbol
    public let night: Bool
    /// "11°"; nil when the forecast has no temperature for now.
    public let temperature: String?
    /// "Partly cloudy".
    public let sky: String
    /// "High 14° · low 8° in the next 12 hours".
    public let span: String
}

/// One hour's temperature bar. `share` (0...1) is its height in the strip; every third bar
/// carries its sky, hour and degrees.
public struct WeatherTemperatureBar: Equatable, Sendable, Identifiable {
    public let id: String
    public let share: Double
    public let freezing: Bool
    public let mark: Mark?

    public struct Mark: Equatable, Sendable {
        public let symbol: WeatherSymbol
        public let night: Bool
        public let hour: String
        public let degrees: String
    }
}

/// The WHO's bands of the UV index.
public enum UvBand: String, Equatable, Sendable {
    case none, low, moderate, high
    case veryHigh = "very high"
    case extreme
}

/// The UV index now, its 12 hours on one fixed scale and when it peaks.
public struct WeatherUvPanel: Equatable, Sendable {
    /// The index now as the whole number its bands are known by.
    public let value: String
    public let band: UvBand
    /// "Peak 6 (high) at 13:00", or that there is none.
    public let caption: String
    public let bars: [Bar]

    /// `share` is nil for an hour without a value: a gap, not a zero.
    public struct Bar: Equatable, Sendable, Identifiable {
        public let id: String
        public let share: Double?
        public let band: UvBand
        public let label: String?
    }
}

/// One day of the forecast: "Tue", its sky, "14°", "8°", "80 %".
public struct WeatherDayRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let symbol: WeatherSymbol
    public let high: String
    public let low: String
    public let chance: String?
    /// Whether the chance is worth the eye: the row tints it.
    public let rainLikely: Bool
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

    // MARK: Forecast

    /// The top of the UV bars' scale: fixed, so a bar means the same in July and in November.
    public static let uvScaleMax = 11.0
    /// The chance of rain from which a day's figure is tinted.
    public static let rainLikelyChance = 10

    /// Nil when the forecast did not answer.
    public func summary(_ conditions: WeatherConditions?) -> WeatherSummary? {
        guard let conditions, let symbol = conditions.symbol, let high = conditions.tempMax,
            let low = conditions.tempMin
        else { return nil }
        return WeatherSummary(
            symbol: symbol, night: conditions.night, temperature: conditions.tempNow.map(degrees),
            sky: skyWord(symbol, night: conditions.night),
            span: "High \(degrees(high)) · low \(degrees(low)) in the next 12 hours")
    }

    /// One line in place of the forecast when its source failed while a location is known; the
    /// rain rows stand without it.
    public func forecastNote(_ conditions: WeatherConditions?) -> String? {
        conditions?.reason == .sourceUnavailable
            ? "Forecast unreachable · temperature, UV and the next days are missing" : nil
    }

    /// The 12 hours between their lowest and highest temperature. The lowest keeps a quarter of
    /// the height so it still reads as a bar, and a flat day sits at half.
    public func temperatureBars(_ conditions: WeatherConditions?) -> [WeatherTemperatureBar] {
        let hours = conditions?.hours ?? []
        guard let low = hours.map(\.temp).min(), let high = hours.map(\.temp).max() else { return [] }
        return hours.enumerated().map { index, hour in
            let share = high == low ? 0.5 : 0.25 + 0.75 * Double(hour.temp - low) / Double(high - low)
            var mark: WeatherTemperatureBar.Mark?
            if index % 3 == 0 {
                mark = WeatherTemperatureBar.Mark(
                    symbol: hour.symbol, night: hour.night,
                    hour: hour.startDate.map(hourOfDay) ?? "", degrees: degrees(hour.temp))
            }
            return WeatherTemperatureBar(id: hour.start, share: share, freezing: hour.temp <= 0, mark: mark)
        }
    }

    /// Nil when the forecast carries no UV index.
    public func uv(_ conditions: WeatherConditions?) -> WeatherUvPanel? {
        guard let conditions, let uv = conditions.uv else { return nil }
        var caption = "No UV in the next 12 hours"
        if let peak = uv.peakDate, uvWhole(uv.peak) > 0 {
            caption = "Peak \(uvWhole(uv.peak)) (\(uvBand(uv.peak).rawValue)) at \(dayClock(peak))"
        }
        let bars = conditions.hours.enumerated().map { index, hour in
            WeatherUvPanel.Bar(
                id: hour.start, share: hour.uv.map { min($0, Self.uvScaleMax) / Self.uvScaleMax },
                band: hour.uv.map(uvBand) ?? UvBand.none,
                label: index % 3 == 0 ? hour.startDate.map(hourOfDay) : nil)
        }
        return WeatherUvPanel(value: "\(uvWhole(uv.now))", band: uvBand(uv.now), caption: caption, bars: bars)
    }

    /// Today and the days after it. A day is named from its date as written, which is the
    /// location's own calendar day, never moved through the phone's time zone.
    public func days(_ conditions: WeatherConditions?) -> [WeatherDayRow] {
        (conditions?.days ?? []).enumerated().map { index, day in
            WeatherDayRow(
                id: day.date, name: index == 0 ? "Today" : weekday(of: day.date) ?? day.date,
                symbol: day.symbol, high: degrees(day.tempMax), low: degrees(day.tempMin),
                chance: day.chance.map(percent), rainLikely: (day.chance ?? 0) >= Self.rainLikelyChance)
        }
    }

    /// The index as the whole number its bands are known by: 2.5 is 3, moderate.
    public func uvBand(_ uv: Double) -> UvBand {
        switch uvWhole(uv) {
        case 11...: return .extreme
        case 8...: return .veryHigh
        case 6...: return .high
        case 3...: return .moderate
        case 1...: return .low
        default: return UvBand.none
        }
    }

    /// The sky's classes in words; a clear night is not sunny.
    public func skyWord(_ symbol: WeatherSymbol, night: Bool) -> String {
        switch symbol {
        case .clear: return night ? "Clear" : "Sunny"
        case .partly: return "Partly cloudy"
        case .cloudy: return "Cloudy"
        case .fog: return "Fog"
        case .rain: return "Rain"
        case .sleet: return "Sleet"
        case .snow: return "Snow"
        case .thunder: return "Thunderstorm"
        case let .unrecognized(raw): return raw
        }
    }

    private func uvWhole(_ uv: Double) -> Int { Int(uv.rounded()) }

    private func degrees(_ temp: Int) -> String { "\(temp)°" }

    /// "Tue" for "2026-11-17".
    private func weekday(of date: String) -> String? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        guard let day = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][utc.component(.weekday, from: day) - 1]
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
