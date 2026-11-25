import PAIKit
import SwiftUI

/// What the app shows instead of the session list while sleep mode is on: the Apps list as the
/// main screen, without the apps that are about the agents. It is drawn from `AppRegistry`, the
/// same list the Apps sheet is drawn from, so an app added there appears here with no further edit.
struct SleepScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var waking = false

    private var sleep: SleepModeStore { environment.sleepMode }
    private var capabilities: Capabilities { environment.connection?.me.capabilities ?? .unknown }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

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

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AppRegistry.listedAtNight(for: capabilities)) { entry in
                        tile(entry)
                    }
                }

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
        .fixtureFact(
            "sleepTiles", AppRegistry.listedAtNight(for: capabilities).map(\.id).joined(separator: ","))
    }

    private var subtitle: String {
        guard let end = sleep.windowEnd else { return "Sessions are resting" }
        return "Sessions are resting until \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func tile(_ entry: AppEntry) -> some View {
        Button {
            environment.router.push(entry.route)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: entry.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(PaiPalette.primary400)
                Text(entry.title)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 86)
            .background(PaiPalette.Semantic.raisedSurface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(PaiPalette.Semantic.borderDefault, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sleep-tile-\(entry.id)")
    }
}
