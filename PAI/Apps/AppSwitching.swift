import PAIKit
import SwiftUI

extension AppEnvironment {
    private var capabilities: Capabilities { connection?.me.capabilities ?? .unknown }

    /// The person's order of apps as their settings hold it.
    var appOrder: [String] { connection?.settings.registry.appOrder ?? [] }

    /// The apps this person can open right now, in their order.
    var arrangedApps: AppOrder.Arranged {
        AppRegistry.arranged(for: capabilities, order: appOrder, asleep: router.isAsleep)
    }

    /// Every app this person has, in their order, whatever the hour: what settings arranges.
    var arrangeableApps: AppOrder.Arranged {
        AppRegistry.arranged(for: capabilities, order: appOrder, asleep: false)
    }

    /// The app the person is in, or `nil` on the start screen and on a screen of no app.
    var currentAppID: String? { AppRegistry.appID(of: router.path) }

    /// Goes to an app, on the screens it was left on. Todos opens on the page it was on last when
    /// it has no screens kept.
    func open(_ entry: AppEntry) {
        let start = entry.route == .todos ? TodosEntry.route(self) : nil
        router.replace(
            with: appPlaces.path(switchingTo: entry, start: start, from: router.path, asleep: router.isAsleep))
    }
}

/// The top bar's way to every other app: it opens the Apps list. The same button on every app's
/// first screen, on the session list and in a session.
struct AppsButton: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button {
            environment.appPlaces.isShowingApps = true
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityLabel("Apps")
        .accessibilityIdentifier("open-apps")
    }
}

extension View {
    /// Puts the Apps button into this screen's top bar.
    func appsButton() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) { AppsButton() }
        }
    }
}

/// One app as a tile: the start screen and the sleep screen are grids of these.
struct AppTile: View {
    let entry: AppEntry
    let identifier: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
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
        .accessibilityIdentifier(identifier)
    }
}

/// The apps as tiles in the person's order: the ones shown directly, then the rest under "More".
struct AppTileGrid: View {
    let apps: AppOrder.Arranged
    let identifierPrefix: String
    let open: (AppEntry) -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            grid(apps.pinned)
            if !apps.pinned.isEmpty, !apps.more.isEmpty {
                Text("More")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .padding(.top, 8)
            }
            grid(apps.more)
        }
    }

    private func grid(_ entries: [AppEntry]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(entries) { entry in
                AppTile(entry: entry, identifier: "\(identifierPrefix)-\(entry.id)") { open(entry) }
            }
        }
    }
}
