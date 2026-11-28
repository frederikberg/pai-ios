import PAIKit
import SwiftUI

/// What the app shows instead of the session list while sleep mode is on: the start screen's
/// tiles in the person's order, without the apps that are about the agents. It is drawn from
/// `AppRegistry`, the same list the start screen and the Apps list are drawn from, so an app
/// added there appears here with no further edit.
struct SleepScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var waking = false

    private var sleep: SleepModeStore { environment.sleepMode }
    private var capabilities: Capabilities { environment.connection?.me.capabilities ?? .unknown }

    /// The night's apps in the person's order, whatever the clock says while this screen is up.
    private var apps: AppOrder.Arranged {
        AppRegistry.arranged(for: capabilities, order: environment.appOrder, asleep: true)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(PaiPalette.primary300)
                        .accessibilityHidden(true)
                    Text("Sleep mode")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(PaiPalette.Semantic.textStrong)
                    Text(subtitle)
                        .font(PaiTypography.body.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .accessibilityIdentifier("sleep-subtitle")
                }
                .padding(.top, 24)

                AppTileGrid(apps: apps, identifierPrefix: "sleep-tile") { environment.open($0) }

                Button("Wake early…") { waking = true }
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("sleep-wake-early")
            }
            .padding(.horizontal, 16)
        }
        .paiScreenBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("open-settings")
            }
        }
        .sheet(isPresented: $waking) {
            PinEntrySheet(title: "Wake early", check: { sleep.wakeEarly(pin: $0) }, onAccepted: { _ in })
        }
        .accessibilityIdentifier("sleep-screen")
        .fixtureFact("sleepScreen", "on")
        .fixtureFact("sleepTiles", apps.all.map(\.id).joined(separator: ","))
    }

    private var subtitle: String {
        guard let end = sleep.windowEnd else { return "Sessions are resting" }
        return "Sessions are resting until \(end.formatted(date: .omitted, time: .shortened))"
    }
}
