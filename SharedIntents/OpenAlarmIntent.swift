import AppIntents
import Foundation
import PAIKit

// Compiled into the app and into the controls extension, for the same reason as
// `OpenQuickActionsIntent`: the control opens the app only when the app holds this very type.

/// Open the Alarm app — what the Alarm control opens, and available to Shortcuts on its own.
struct OpenAlarmIntent: AppIntent {
    static var title: LocalizedStringResource { "Alarm" }
    static var description: IntentDescription {
        IntentDescription("Open PAI's alarm app.")
    }
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkInbox.shared.receive(.alarm(id: nil))
        return .result()
    }
}
