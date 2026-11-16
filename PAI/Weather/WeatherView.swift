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
                    RainRow(title: "Later", row: presenter.laterRow(weather.later), identifier: "weather-later")
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
