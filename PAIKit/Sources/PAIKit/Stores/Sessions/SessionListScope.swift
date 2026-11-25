/// Which sessions the list is about. The three are exclusive views over the same sessions, not
/// filters layered on one another, and independent of the machine choice, "Hide closed sessions"
/// and the search: those narrow further within whichever view is chosen.
public enum SessionListScope: String, CaseIterable, Sendable {
    /// Sessions the user started: scheduled-task sessions are left out. The default.
    case manual
    /// Only the sessions a scheduled task started.
    case scheduled
    /// Every session, scheduled-task sessions included.
    case both

    /// What the segmented control shows.
    public var title: String {
        switch self {
        case .manual: "Manual"
        case .scheduled: "Scheduled"
        case .both: "Both"
        }
    }

    /// Whether a session belongs to this view. A scheduled session carries the id of the task
    /// that started it.
    public func includes(_ session: Session) -> Bool {
        switch self {
        case .manual: session.taskId == nil
        case .scheduled: session.taskId != nil
        case .both: true
        }
    }
}
