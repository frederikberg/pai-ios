import PAIKit
import SwiftUI

/// Today: where the person is in the day. The ribbon, the body lines, a write card, the tasks
/// card, the plan and the diary's newest.
struct MeTodayView: View {
    let store: MeOverviewStore
    let write: (SelfReportFeel?) -> Void
    let showDays: (String) -> Void
    let showDiary: () -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(SelfReportStore.self) private var reports

    var body: some View {
        if let overview = store.overview {
            let presenter = store.presenter
            let sections = drawnSections(overview, presenter)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(overview, presenter)
                    ForEach(sections, id: \.self) { section in
                        sectionView(section, overview, presenter)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .fixtureScrollsToAnchor()
            .refreshable { await store.load(freshTasks: true) }
            .fixtureFact("meTodaySections", sections.map(\.rawValue).joined(separator: ","))
        } else if store.isLoading {
            Spacer()
            Text("Loading…").font(PaiTypography.body.font).foregroundStyle(PaiPalette.Semantic.textMuted)
            Spacer()
        } else {
            Text("Me could not be loaded. Pull down to try again.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        }
    }

    // MARK: Sections

    /// What Today draws, in order: the ribbon, the tasks card and the plan only while they hold something.
    private func drawnSections(_ overview: MeOverview, _ presenter: MePresenter) -> [MeLayout.TodaySection] {
        let day = store.today
        let ribbon = day.map { presenter.ribbon(day: $0, tasks: store.todayTasks, now: nil).hasData } ?? false
        return MeLayout.todaySections(
            for: overview, ribbon: ribbon, tasks: tasksCard(overview, presenter, now: Date()) != nil,
            plan: presenter.planCard(day?.plan, todayKey: overview.today) != nil)
    }

    private func tasksCard(_ overview: MeOverview, _ presenter: MePresenter, now: Date) -> MeTodayCard? {
        presenter.todayCard(
            tasks: store.todayTasks, events: store.today?.events ?? [], now: now, todayKey: overview.today)
    }

    @ViewBuilder
    private func sectionView(_ section: MeLayout.TodaySection, _ overview: MeOverview, _ presenter: MePresenter)
        -> some View
    {
        switch section {
        case .ribbon: ribbonCard(overview, presenter)
        case .body: bodyCard(overview, presenter)
        case .write: writeCard
        case .review:
            if let review = overview.review { reviewCard(review) }
        case .tasks: tasksSection(overview, presenter)
        case .plan:
            if let plan = presenter.planCard(store.today?.plan, todayKey: overview.today) {
                MePlanCardView(card: plan).id(FixtureScrollAnchor.mePlan.rawValue)
            }
        case .diary: diary(overview, presenter)
        case .lookingBack:
            if let looking = overview.lookingBack { lookingBack(looking, presenter) }
        case .pai: paiLine(presenter)
        case .notes: notes(overview)
        }
    }

    private func header(_ overview: MeOverview, _ presenter: MePresenter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presenter.weekdayName(key: overview.today))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(PaiPalette.Semantic.textStrong)
            Text(presenter.dayHeaderCaption(key: overview.today))
                .font(PaiTypography.panelTitle.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            if let line = presenter.sourcesLine(
                overview: overview, tasks: store.todayTasks, todayFinal: store.today?.final, now: Date())
            {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .padding(.top, 2)
                    .accessibilityIdentifier("me-sources")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("me-today-header")
    }

    private func caption(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title.uppercased())
                .font(PaiTypography.captionEmphasized.font)
                .tracking(0.8)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Spacer()
            if let trailing {
                Text(trailing).font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().meCard()
    }

    /// The day on the clock, once a minute; a tap opens the day's detail.
    @ViewBuilder
    private func ribbonCard(_ overview: MeOverview, _ presenter: MePresenter) -> some View {
        if let day = store.today {
            TimelineView(.everyMinute) { context in
                Button {
                    showDays(overview.today)
                } label: {
                    MeRibbonView(ribbon: presenter.ribbon(day: day, tasks: store.todayTasks, now: context.date))
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .meCard(padding: 0)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func bodyCard(_ overview: MeOverview, _ presenter: MePresenter) -> some View {
        let lines = presenter.bodyLines(day: store.today)
        if !overview.sources.garminConnected {
            Text("Garmin not connected")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .accessibilityIdentifier("me-body-quiet")
        } else if !lines.isEmpty {
            MeBodyCardView(lines: lines)
        }
    }

    @ViewBuilder
    private func tasksSection(_ overview: MeOverview, _ presenter: MePresenter) -> some View {
        if let card = tasksCard(overview, presenter, now: Date()) {
            MeTodayCardView(card: card, isRefreshing: store.isRefreshingTasks) {
                Task { await store.refreshTasks() }
            }
            .id(FixtureScrollAnchor.meTasks.rawValue)
            .fixtureFact("meTasksOpen", "\(card.desk.map(\.rows.count).reduce(card.open.count, +))")
        }
    }

    private var writeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    write(nil)
                } label: {
                    HStack(spacing: 8) {
                        if recording {
                            Circle().fill(PaiPalette.Semantic.errorText).frame(width: 8, height: 8)
                        }
                        Text(recording ? "Recording…" : draftLine)
                            .font(.system(size: 17))
                            .foregroundStyle(
                                reports.draft.text.isEmpty || recording
                                    ? PaiPalette.Semantic.textMuted : PaiPalette.Semantic.textPrimary
                            )
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PaiPalette.Semantic.insetBackground, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me-write-field")
                HStack(spacing: 12) {
                    ForEach(SelfReportFeel.allCases, id: \.wire) { feel in
                        Button {
                            write(feel)
                        } label: {
                            FeelFace(feel: feel, size: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Write, feeling \(feel.spokenName.lowercased())")
                        .accessibilityIdentifier("me-write-face-\(feel.wire ?? "other")")
                    }
                    Spacer()
                    Text("a face, a few words, or nothing")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    /// A take dictating into the diary draft keeps running when the composer closes.
    private var recording: Bool {
        environment.connection?.voice.isRecording(draftKey: SelfReportStore.dictationKey) == true
    }

    private var draftLine: String {
        let text = reports.draft.text.replacingOccurrences(of: VoiceRecordingResult.sttPrefix, with: "")
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)
        return first ?? "Anything about today…"
    }

    private func reviewCard(_ review: MeReview) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    environment.router.push(.note(id: review.noteId))
                } label: {
                    HStack {
                        Text(review.week.map { "Week \($0) review" } ?? review.title)
                            .font(PaiTypography.panelTitle.font)
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me-review")
                // Only while the review names the talk's session.
                if let sessionId = review.compassSessionId {
                    Button {
                        environment.router.push(.session(id: sessionId, messageID: nil))
                    } label: {
                        HStack {
                            Label("Compass talk", systemImage: "safari")
                                .font(PaiTypography.bodyEmphasized.font)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(PaiPalette.Semantic.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("me-compass")
                }
            }
        }
    }

    /// The numbers about PAI: one grey line, below everything about him.
    @ViewBuilder
    private func paiLine(_ presenter: MePresenter) -> some View {
        if let day = store.today, let pai = day.pai {
            let sessions = pai.sessions.map { " in \($0) session\($0 == 1 ? "" : "s")" } ?? ""
            VStack(alignment: .leading, spacing: 2) {
                Text("PAI today · \(pai.messages) message\(pai.messages == 1 ? "" : "s")\(sessions)")
                if let morning = presenter.morningLine(day) { Text(morning) }
            }
            .font(PaiTypography.body.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .accessibilityIdentifier("me-pai")
        }
    }

    private func diary(_ overview: MeOverview, _ presenter: MePresenter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption("Diary")
                Button("All entries ›") { showDiary() }
                    .font(PaiTypography.body.font)
                    .accessibilityIdentifier("me-all-entries")
            }
            if overview.recentEntries.isEmpty {
                Text(
                    "Nothing here yet. Write when you feel like it — a face, a sentence, a whole evening. Nobody counts."
                )
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            ForEach(overview.recentEntries) { entry in
                MeEntryRow(item: MeDiaryItem(report: entry, waiting: false, refusal: nil), presenter: presenter)
            }
        }
        .id(FixtureScrollAnchor.meDiary.rawValue)
    }

    private func lookingBack(_ entry: SelfReport, _ presenter: MePresenter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Looking back")
            MeEntryRow(item: MeDiaryItem(report: entry, waiting: false, refusal: nil), presenter: presenter)
        }
    }

    @ViewBuilder
    private func notes(_ overview: MeOverview) -> some View {
        if !overview.notes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(overview.notes) { note in
                        Button(note.title) { environment.router.push(.note(id: note.noteId)) }
                            .font(PaiTypography.body.font)
                    }
                }
            }
            .accessibilityIdentifier("me-notes")
        }
    }
}
