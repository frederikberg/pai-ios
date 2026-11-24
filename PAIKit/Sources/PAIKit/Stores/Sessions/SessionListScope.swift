/// Which sessions the list is about. The three are exclusive views over the same sessions, not
/// filters layered on one another, and independent of the machine chips and the search: those
/// narrow further within whichever view is chosen.
public enum SessionListScope: String, CaseIterable, Sendable {
    /// The ordinary list: scheduled-task sessions are left out. The default.
    case all
    /// Every session, scheduled-task sessions included.
    case allPlus
    /// Only the sessions a scheduled task started.
    case scheduled

    /// What the segmented control shows.
    public var title: String {
        switch self {
        case .all: "All"
        case .allPlus: "All+"
        case .scheduled: "Scheduled"
        }
    }

    /// Whether a session belongs to this view. A scheduled session carries the id of the task
    /// that started it.
    public func includes(_ session: Session) -> Bool {
        switch self {
        case .all: session.taskId == nil
        case .allPlus: true
        case .scheduled: session.taskId != nil
        }
    }
}
