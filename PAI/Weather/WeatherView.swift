import PAIKit
import SwiftUI

/// The Weather app: two calm rows answering the two morning questions. "Now" is whether rain
/// pants are needed for the next hour (radar), "Later" whether to pack them for the next twelve
/// hours. The footer says where, how fresh the location is, and whose data this is.
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
                    RainRow(title: "Now", row: presenter.nowRow(weather.now), identifier: "weather-now")
                    VStack(alignment: .leading, spacing: 12) {
                        RainRow(title: "Later", row: presenter.laterRow(weather.later), identifier: "weather-later")
                        let bars = presenter.strip(weather.later)
                        if !bars.isEmpty { HourStrip(bars: bars) }
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
