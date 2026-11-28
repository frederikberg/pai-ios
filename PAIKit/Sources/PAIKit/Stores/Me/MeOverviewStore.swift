import Foundation
import Observation

/// What Today and the 14-day grid show: the overview, the day picked in the grid, that day's
/// detail and its task rows. A failed read keeps the answer on screen and says so.
@MainActor
@Observable
public final class MeOverviewStore {
    public static let windowDays = 14

    public private(set) var overview: MeOverview?
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    /// The grid's last day as `yyyy-MM-dd`; nil is "today" and keeps the window following it.
    public private(set) var windowEnd: String?
    public var selectedDate: String?
    public private(set) var detail: MeDay?
    public private(set) var detailDate: String?
    /// The task rows read so far, by Berlin day. Today's are read again on open, on coming back
    /// to the screen and on the refresh icon, never on a timer.
    public private(set) var tasksByDate: [String: MeTasks] = [:]
    public private(set) var isRefreshingTasks = false

    private let api: SelfReportApiClient
    private var presenterCache: MePresenter?

    public init(api: SelfReportApiClient) {
        self.api = api
    }

    /// The presenter for the overview's own zone.
    public var presenter: MePresenter {
        if let presenterCache { return presenterCache }
        return MePresenter(timeZoneName: overview?.timezone ?? "Europe/Berlin")
    }

    /// Reads the overview and today's task rows side by side, then the picked day's detail.
    /// `freshTasks` is a pull-to-refresh: it asks the server to read Todos again even when its last read is recent.
    public func load(readingTasks: Bool = true, freshTasks: Bool = false) async {
        async let todayTasks: Void = readTodayTasks(readingTasks, fresh: freshTasks)
        await loadOverview()
        await todayTasks
    }

    private func readTodayTasks(_ reading: Bool, fresh: Bool) async {
        if reading { await loadTasks(date: nil, fresh: fresh) }
    }

    private func loadOverview() async {
        defer { isLoading = false }
        do {
            let answer = try await api.getMeOverview(days: Self.windowDays, end: windowEnd)
            overview = answer
            presenterCache = MePresenter(timeZoneName: answer.timezone)
            errorMessage = nil
            if selectedDate == nil || !answer.days.contains(where: { $0.date == selectedDate }) {
                selectedDate = answer.days.last?.date
            }
            if let selectedDate { await loadDetail(date: selectedDate, force: true) }
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the overview"
        }
    }

    /// The window of the 14 days before the one shown.
    public func earlier() async {
        guard let first = overview?.days.first?.date, let end = presenter.shift(key: first, byDays: -1) else { return }
        windowEnd = end
        selectedDate = nil
        await load(readingTasks: false)
    }

    /// The window of the 14 days after the one shown; the window that reaches today follows it again.
    public func later() async {
        guard let last = overview?.days.last?.date, let today = overview?.today,
            let end = presenter.shift(key: last, byDays: Self.windowDays)
        else { return }
        windowEnd = end >= today ? nil : end
        selectedDate = nil
        await load(readingTasks: false)
    }

    public var canGoLater: Bool { windowEnd != nil }

    public func select(date: String) async {
        selectedDate = date
        await loadDetail(date: date, force: false)
    }

    /// The day route answers with entries in full and what the day held, with summaries; the
    /// overview alone has neither. Read when a day is picked, since it may regenerate summaries.
    private func loadDetail(date: String, force: Bool) async {
        if !force, detailDate == date, detail != nil { return }
        async let dayTasks: Void = loadTasksUnlessToday(date: date)
        await readDetail(date: date)
        await dayTasks
    }

    private func readDetail(date: String) async {
        do {
            let day = try await api.getMeDay(date: date)
            // A newer pick may have come in while this answered.
            guard selectedDate == date else { return }
            detail = day
            detailDate = date
        } catch {
            if selectedDate == date {
                detail = nil
                detailDate = date
            }
        }
    }

    // MARK: Tasks

    /// Today's rows come with ``load()``; another day's are stored ones the server never asks
    /// Todos for, read once when the day is picked.
    private func loadTasksUnlessToday(date: String) async {
        if date == overview?.today || tasksByDate[date] != nil { return }
        await loadTasks(date: date, fresh: false)
    }

    /// Reads one day's rows (`date` nil is today). A failed read keeps what is held, so an error
    /// never replaces rows already on screen.
    public func loadTasks(date: String?, fresh: Bool) async {
        do {
            let answer = try await api.getMeTasks(date: date, fresh: fresh)
            tasksByDate[answer.date] = answer
        } catch {
            // Nothing to show for it: the card keeps its last rows, or is not drawn.
        }
    }

    /// The refresh icon: asks the server to read Todos again when its last read is a few
    /// seconds old, which the server allows at most every 20 seconds.
    public func refreshTasks() async {
        guard !isRefreshingTasks else { return }
        isRefreshingTasks = true
        defer { isRefreshingTasks = false }
        await loadTasks(date: nil, fresh: true)
    }

    public var todayTasks: MeTasks? { overview.flatMap { tasksByDate[$0.today] } }

    public var selectedTasks: MeTasks? { selectedDate.flatMap { tasksByDate[$0] } }

    public var selectedDay: MeDay? { overview?.days.first { $0.date == selectedDate } }

    /// The day the selected one is drawn from: the full answer when it is the picked day's, else
    /// what the overview carries.
    public var selectedDetail: MeDay? {
        if let detail, detailDate == selectedDate { return detail }
        return selectedDay
    }

    public var today: MeDay? { overview?.days.first { $0.date == overview?.today } }
}
