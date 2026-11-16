/// Which of the system's delivered alarm banners are stale: the alarm they announce has stopped
/// ringing. Pure, so the decision is tested on Linux without `UserNotifications`.
public enum AlarmDelivery {
    /// `pai_kind` of the background push the backend sends when a ring ends.
    public static let stoppedKind = "alarm_stopped"
    public static let kindKey = "pai_kind"

    /// One delivered notification: its system identifier and the `pai_alarm_id` it carries, if any.
    public struct Delivered: Equatable, Sendable {
        public let identifier: String
        public let alarmID: String?

        public init(identifier: String, alarmID: String?) {
            self.identifier = identifier
            self.alarmID = alarmID
        }
    }

    /// The alarm a background `alarm_stopped` push names, or nil for any other payload.
    public static func stoppedAlarmID(in payload: [String: String]) -> String? {
        guard payload[kindKey] == stoppedKind, let id = payload[DeepLink.alarmIDKey], !id.isEmpty else { return nil }
        return id
    }

    /// Banners to remove when the app opens: every alarm banner whose alarm is not ringing now.
    /// `ringingIDs` comes from a successful read of the list; a notification that names no alarm
    /// is never touched.
    public static func identifiersToClear(delivered: [Delivered], ringingIDs: Set<String>) -> [String] {
        delivered.compactMap { item in
            guard let alarmID = item.alarmID, !ringingIDs.contains(alarmID) else { return nil }
            return item.identifier
        }
    }

    /// Banners to remove when a ring ends: those of that one alarm.
    public static func identifiers(of alarmID: String, in delivered: [Delivered]) -> [String] {
        delivered.filter { $0.alarmID == alarmID }.map(\.identifier)
    }
}
