import PAIKit
import SwiftUI
import UIKit

/// The Weather app: two calm rows answering the two morning questions. "Now" is whether rain
/// pants are needed for the next hour (radar), "Later" whether to pack them for the next twelve
/// hours. Around them the forecast: the sky and the temperature above, then the twelve hours'
/// temperature and UV index and the next days. The footer says where, how fresh the location is,
/// and whose data this is.
struct WeatherView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: WeatherStore?

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Weather")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let current: WeatherStore
            if let store {
                current = store
            } else if let client = environment.connection?.apiClient {
                current = WeatherStore(api: client)
                store = current
            } else {
                return
            }
            await current.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store?.load() } }
        }
        .onChange(of: store?.errorMessage) { _, message in
            if let message { toasts.show(message, kind: .error) }
        }
        .fixtureFact("weatherNowVerdict", "\(store?.weather?.now.verdict.factName ?? "none")")
        .fixtureFact("weatherLaterVerdict", "\(store?.weather?.later.verdict.factName ?? "none")")
    }

    @ViewBuilder
    private func content(_ store: WeatherStore) -> some View {
        if let weather = store.weather {
            let presenter = WeatherPresenter()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let summary = presenter.summary(weather.conditions) {
                        SummaryRow(summary: summary)
                    } else if let note = presenter.forecastNote(weather.conditions) {
                        Text(note)
                            .font(PaiTypography.body.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                            .accessibilityIdentifier("weather-no-forecast")
                    }
                    RainRow(title: "Now", row: presenter.nowRow(weather.now), identifier: "weather-now")
                    VStack(alignment: .leading, spacing: 12) {
                        RainRow(title: "Later", row: presenter.laterRow(weather.later), identifier: "weather-later")
                        let bars = presenter.strip(weather.later)
                        if !bars.isEmpty { HourStrip(bars: bars) }
                    }
                    ForecastSections(
                        temperature: presenter.temperatureBars(weather.conditions),
                        uv: presenter.uv(weather.conditions), days: presenter.days(weather.conditions))
                    if let data = store.radarPicture, let picture = UIImage(data: data) {
                        RadarPicture(image: picture, data: data, at: weather.radarPictureDate)
                    }
                    Text(presenter.footer(weather))
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .accessibilityIdentifier("weather-footer")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await store.load() }
        } else if store.isLoading {
            ProgressView()
        } else {
            Text("The weather could not be loaded. Pull down to try again.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        }
    }
}

private struct RainRow: View {
    let title: String
    let row: WeatherRow
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(PaiTypography.captionEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.value)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint)
                if let detail = row.detail {
                    Text("· \(detail)")
                        .font(PaiTypography.panelTitle.font)
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                }
            }
            if let caption = row.caption {
                Text(caption)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var tint: Color {
        switch row.verdict {
        case .rain: PaiPalette.Semantic.accentText
        case .maybe: PaiPalette.Semantic.warningText
        default: PaiPalette.Semantic.textStrong
        }
    }
}

/// A section's small capital heading.
private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
    }
}

/// The sky as a symbol in its own colour; a sky that shows the sun shows the moon at night.
private struct SkyIcon: View {
    let symbol: WeatherSymbol
    let night: Bool

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .accessibilityLabel(WeatherPresenter().skyWord(symbol, night: night))
    }

    private var name: String {
        switch symbol {
        case .clear: night ? "moon.fill" : "sun.max.fill"
        case .partly: night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy, .unrecognized: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .rain: "cloud.rain.fill"
        case .sleet: "cloud.sleet.fill"
        case .snow: "cloud.snow.fill"
        case .thunder: "cloud.bolt.rain.fill"
        }
    }

    private var tint: Color {
        switch symbol {
        case .clear, .partly: night ? Color.indigo : Color.orange
        case .rain, .sleet: Color(red: 0.05, green: 0.65, blue: 0.91)
        case .snow: Color.cyan
        case .thunder: Color.purple
        case .cloudy, .fog, .unrecognized: PaiPalette.Semantic.textMuted
        }
    }
}

/// The sky over the next twelve hours with the temperature now and the span it moves in.
private struct SummaryRow: View {
    let summary: WeatherSummary

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SkyIcon(symbol: summary.symbol, night: summary.night)
                .font(.system(size: 44))
            if let temperature = summary.temperature {
                Text(temperature)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .foregroundStyle(PaiPalette.Semantic.textStrong)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.sky)
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textStrong)
                Text(summary.span)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("weather-summary")
    }
}

/// The forecast below the rain rows; a part the answer cannot fill is not drawn.
private struct ForecastSections: View {
    let temperature: [WeatherTemperatureBar]
    let uv: WeatherUvPanel?
    let days: [WeatherDayRow]

    var body: some View {
        if !temperature.isEmpty { TemperatureStrip(bars: temperature) }
        if let uv { UvSection(panel: uv) }
        if !days.isEmpty { DaysSection(days: days) }
    }
}

/// Twelve bars between the hours' lowest and highest temperature, ice blue at or below freezing;
/// every third hour carries its sky above and its hour and degrees below.
private struct TemperatureStrip: View {
    let bars: [WeatherTemperatureBar]
    private let height: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Temperature")
            HStack(spacing: 2) {
                ForEach(bars) { (bar: WeatherTemperatureBar) in
                    slot { mark(bar.mark) }
                }
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bars) { (bar: WeatherTemperatureBar) in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bar.freezing ? Color.cyan : Color.orange)
                        .frame(height: height * CGFloat(bar.share))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(alignment: .top, spacing: 2) {
                ForEach(bars) { (bar: WeatherTemperatureBar) in
                    slot { legend(bar.mark) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperature per hour for the next 12 hours")
        .accessibilityIdentifier("weather-temperature")
    }

    /// One of twelve equal columns; its content may run on over the empty columns beside it.
    private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func mark(_ mark: WeatherTemperatureBar.Mark?) -> some View {
        if let mark {
            SkyIcon(symbol: mark.symbol, night: mark.night).font(PaiTypography.body.font)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func legend(_ mark: WeatherTemperatureBar.Mark?) -> some View {
        if let mark {
            VStack(alignment: .leading, spacing: 0) {
                Text(mark.hour)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Text(mark.degrees)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textStrong)
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

extension UvBand {
    /// The band's colour as UV charts draw it, green to violet.
    fileprivate var color: Color {
        switch self {
        case .none: PaiPalette.Semantic.textMuted
        case .low: Color.green
        case .moderate: Color.yellow
        case .high: Color.orange
        case .veryHigh: Color.red
        case .extreme: Color.purple
        }
    }
}

/// The UV index now, named by its band and in the band's colour, then the twelve hours on one
/// fixed scale and when it peaks. An hour without a value leaves a gap.
private struct UvSection: View {
    let panel: WeatherUvPanel
    private let height: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "UV index")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(panel.value)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(panel.band.color)
                Text(panel.band.rawValue)
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(panel.bars) { (bar: WeatherUvPanel.Bar) in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill(bar))
                        .frame(height: barHeight(bar.share))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 2) {
                ForEach(panel.bars) { (bar: WeatherUvPanel.Bar) in
                    Text(bar.label ?? " ")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(panel.caption)
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("weather-uv")
    }

    private func fill(_ bar: WeatherUvPanel.Bar) -> Color {
        guard bar.share != nil else { return Color.clear }
        return bar.band.color.opacity(bar.band == UvBand.none ? 0.3 : 1)
    }

    private func barHeight(_ share: Double?) -> CGFloat {
        max(2, height * CGFloat(share ?? 0))
    }
}

/// Today and the next days, one row each: the sky of its daylight, the highest and lowest
/// temperature and the chance of rain.
private struct DaysSection: View {
    let days: [WeatherDayRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Next days")
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    heading("High")
                    heading("Low")
                    heading("Rain")
                }
                ForEach(days) { (day: WeatherDayRow) in
                    GridRow {
                        Text(day.name)
                            .font(PaiTypography.panelTitle.font)
                            .foregroundStyle(PaiPalette.Semantic.textStrong)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SkyIcon(symbol: day.symbol, night: false)
                        figure(day.high, PaiPalette.Semantic.textStrong)
                        figure(day.low, PaiPalette.Semantic.textMuted)
                        chance(day)
                    }
                }
            }
        }
        .accessibilityIdentifier("weather-days")
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
    }

    private func figure(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(PaiTypography.body.font)
            .foregroundStyle(color)
    }

    private func chance(_ day: WeatherDayRow) -> some View {
        Label(day.chance ?? "–", systemImage: "drop.fill")
            .labelStyle(.titleAndIcon)
            .font(PaiTypography.body.font)
            .foregroundStyle(day.rainLikely ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textMuted)
            .accessibilityLabel("Chance of rain \(day.chance ?? "unknown")")
    }
}

/// The radar about half an hour ahead, drawn by the server from the radar the answer used. A tap
/// opens it in the viewer.
private struct RadarPicture: View {
    let image: UIImage
    let data: Data
    let at: Date?
    @State private var previewTarget: FilePreviewTarget?

    private var title: String {
        guard let at else { return "RADAR" }
        return "RADAR AT \(ClockTime.string(at, calendar: .current))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(PaiTypography.captionEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Button {
                previewTarget = FilePreviewTarget(data: data, filename: "radar.png", kind: .image)
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Radar forecast picture")
            .filePreview($previewTarget)
        }
        .accessibilityIdentifier("weather-radar")
    }
}

/// The twelve hours as bars: height the chance, colour how much rain the hour holds (pale to
/// dark, as the radar map draws light to heavy rain), every third hour labelled.
private struct HourStrip: View {
    let bars: [WeatherStripBar]
    private let height: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bars) { bar in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(bar.intensity))
                        .frame(height: barHeight(bar.chance))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 2) {
                ForEach(bars) { bar in
                    Text(bar.label ?? " ")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rain chance per hour for the next 12 hours")
        .accessibilityIdentifier("weather-hours")
    }

    private func barHeight(_ chance: Int) -> CGFloat {
        let share = CGFloat(max(4, min(100, chance))) / 100
        return height * share
    }

    private func color(_ intensity: RainIntensity) -> Color {
        switch intensity {
        case .light: Color(red: 0.49, green: 0.83, blue: 0.99)
        case .moderate: Color(red: 0.05, green: 0.65, blue: 0.91)
        case .heavy: Color(red: 0.11, green: 0.31, blue: 0.85)
        case .none, .unrecognized: PaiPalette.Semantic.textMuted.opacity(0.3)
        }
    }
}

extension RainVerdict {
    /// The word a screenshot run asserts on.
    fileprivate var factName: String {
        switch self {
        case .rain: "rain"
        case .maybe: "maybe"
        case .unlikely: "unlikely"
        case .dry: "dry"
        case .unknown: "unknown"
        case .unrecognized: "unrecognized"
        }
    }
}
