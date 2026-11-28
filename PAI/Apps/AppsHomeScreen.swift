import PAIKit
import SwiftUI

/// The screen the app starts on: every app as a tile, in the person's order. Back leads to the
/// session list; an app opened from here returns here.
struct AppsHomeScreen: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let apps = environment.arrangedApps
        ScrollView {
            AppTileGrid(apps: apps, identifierPrefix: "apps-tile") { environment.open($0) }
                .padding(16)
        }
        .paiScreenBackground()
        .navigationTitle("Apps")
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
        .accessibilityIdentifier("apps-home")
        .fixtureFact("appsPinned", apps.pinned.map(\.id).joined(separator: ","))
        .fixtureFact("appsMore", apps.more.map(\.id).joined(separator: ","))
    }
}
