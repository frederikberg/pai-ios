import PAIKit
import SwiftUI

struct AppearanceSections: View {
    let settings: SettingsStore

    var body: some View {
        ScopedSection(title: "Look", scope: .thisDevice) {
            Picker("Theme", selection: Binding(get: { settings.theme }, set: { settings.setTheme($0) })) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.rawValue.capitalized).tag(theme)
                }
            }
            .accessibilityIdentifier("theme-picker")
        }
    }
}
