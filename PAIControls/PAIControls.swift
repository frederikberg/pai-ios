import AppIntents
import SwiftUI
import WidgetKit

/// The controls Control Center, the Lock Screen and the Action button offer. Each one runs the
/// intent of the same name from `SharedIntents/`, so a control lands exactly where its shortcut
/// does.
@main
struct PAIControls: WidgetBundle {
    var body: some Widget {
        QuickActionsControl()
        AlarmControl()
    }
}

/// A button control is a single 1x1 tile; there is no size to choose.
struct QuickActionsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.frederikberg.pai.controls.quick-actions") {
            ControlWidgetButton(action: OpenQuickActionsIntent()) {
                Label("Quick actions", systemImage: "square.grid.2x2.fill")
            }
        }
        .displayName("Quick actions")
        .description("Open PAI's quick actions menu.")
    }
}

/// Opens the Alarm app straight onto its list, where "+" arms a new alarm.
struct AlarmControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.frederikberg.pai.controls.alarm") {
            ControlWidgetButton(action: OpenAlarmIntent()) {
                Label("Alarm", systemImage: "alarm.fill")
            }
        }
        .displayName("Alarm")
        .description("Open PAI's alarm app.")
    }
}
