import PAIKit
import SwiftUI

/// Settings as a list of pages in two halves: what is yours (everyone has it, a guest included) and,
/// for the owner, Administration. A page opens on a screen of its own, and every card on it carries
/// a tag that says whose settings it holds.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    /// The page a launch argument opens at once; always `nil` in a Release build.
    @State private var fixtureCategory: SettingsCategory?

    private var capabilities: Capabilities { environment.connection?.me.capabilities ?? .unknown }

    var body: some View {
        List {
            section("Yours", .yours)
            section("Administration", .administration)
            Section {
                Button("Sign out", role: .destructive) { Task { await environment.signOut() } }
                    .accessibilityIdentifier("sign-out")
            }
        }
        .navigationDestination(item: $fixtureCategory) { SettingsCategoryScreen(category: $0) }
        .paiListBackground()
        .navigationTitle("Settings")
        .task { await openFixtureCategory() }
        .task { await tapFixtureRow() }
        .accessibilityIdentifier("settings-screen")
        .fixtureFact(
            "settingsCategories",
            SettingsCategory.allCases.filter { $0.isAvailable(to: capabilities) }.map(\.rawValue).joined(separator: ",")
        )
    }

    @ViewBuilder
    private func section(_ title: String, _ area: SettingsArea) -> some View {
        let categories = SettingsCategory.listed(in: area, for: capabilities)
        if !categories.isEmpty {
            Section(title) {
                ForEach(categories) { category in
                    // A destination link, not a value link: the stack's path is a typed array of
                    // routes, so a link carrying any other value highlights and pushes nothing.
                    NavigationLink {
                        SettingsCategoryScreen(category: category)
                    } label: {
                        HStack(spacing: 12) {
                            CategoryIcon(category: category)
                            Text(category.title)
                            Spacer(minLength: 8)
                            if let value = value(of: category) {
                                Text(value)
                                    .font(PaiTypography.caption.font)
                                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings-open-\(category.rawValue)")
                }
            }
        }
    }

    private func value(of category: SettingsCategory) -> String? {
        category.value(
            theme: settings.theme, sleepWindow: environment.sleepMode.window,
            openAlerts: settings.alerts.alerts?.count)
    }

    /// `-PaiFixtureTapSettingsRow <page>`: activates that row through the accessibility tree, the
    /// same path a tap takes, so a row that highlights without opening its page shows up as a
    /// list on screen. Does nothing in a Release build.
    private func tapFixtureRow() async {
        #if DEBUG
            guard PaiFixtureLaunch.isEnabled(), let name = PaiFixtureLaunch.requestedSettingsRowTap() else { return }
            await FixtureTap.activate(identifier: "settings-open-\(name)")
        #endif
    }

    private func openFixtureCategory() async {
        #if DEBUG
            guard PaiFixtureLaunch.isEnabled(), let name = PaiFixtureLaunch.requestedSettingsCategory(),
                let category = SettingsCategory(rawValue: name)
            else { return }
            fixtureCategory = category
        #endif
    }
}
