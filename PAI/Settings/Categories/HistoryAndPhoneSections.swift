import PAIKit
import SwiftUI

/// What this iPhone remembers of what was dictated and sent. Kept on this phone only.
struct HistorySections: View {
    let settings: SettingsStore

    var body: some View {
        HistorySection(settings: settings)
    }
}

/// What belongs to this iPhone alone: the notes kept for offline use, the text it could not save,
/// and what the app captured when it last crashed.
struct ThisPhoneSections: View {
    let settings: SettingsStore

    var body: some View {
        NotesCacheSection(settings: settings)
        LastCrashSection()
    }
}
