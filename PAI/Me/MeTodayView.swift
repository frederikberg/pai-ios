import PAIKit
import SwiftUI

/// Today: how the day is going. A write card, the numbers so far, the week, the diary's newest.
struct MeTodayView: View {
    let store: MeOverviewStore
    let write: (SelfReportFeel?) -> Void
    let showDays: (String) -> Void
    let showDiary: () -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(SelfReportStore.self) private var reports
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        if let overview = store.overview {
            let presenter = store.presenter
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(overview, presenter)
                    ForEach(MeLayout.todaySections(for: overview), id: \.self) { section in
                        sectionView(section, overview, presenter)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .refreshable { await store.load() }
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

    @ViewBuilder
    private func sectionView(_ section: MeLayout.TodaySection, _ overview: MeOverview, _ presenter: MePresenter)
        -> some View
    {
        switch section {
        case .write: writeCard
        case .review:
            if let review = overview.review { reviewCard(review) }
        case .soFar: soFar(overview, presenter)
        case .week: week(overview, presenter)
        case .diary: diary(overview, presenter)
        case .lookingBack:
            if let looking = overview.lookingBack { lookingBack(looking, presenter) }
        case .pai: paiCard(presenter)
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
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(PaiPalette.Semantic.borderDefault, lineWidth: 1))
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

    private func soFar(_ overview: MeOverview, _ presenter: MePresenter) -> some View {
        let day = store.today
        let garmin = overview.sources.garminConnected
        let cells = cellsFor(day, presenter, garmin: garmin)
        return VStack(alignment: .leading, spacing: 8) {
            caption("Today so far", trailing: garmin && day?.final == false ? "Garmin · not final yet" : nil)
            card {
                VStack(alignment: .leading, spacing: 14) {
                    if cells.isEmpty && !garmin {
                        Text("Garmin not connected")
                            .font(PaiTypography.body.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    if !cells.isEmpty {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading),
                            ],
                            alignment: .leading, spacing: 14
                        ) {
                            ForEach(cells) { cell in factCell(cell) }
                        }
                    }
                    if !garmin && !cells.isEmpty {
                        Text("Garmin not connected")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    let lines = [presenter.planLine(day?.plan)].compactMap { $0 }
                    if !lines.isEmpty {
                        Divider().overlay(PaiPalette.Semantic.borderDefault)
                        ForEach(lines, id: \.self) { line in
                            Text(line).font(PaiTypography.body.font).foregroundStyle(PaiPalette.Semantic.textSecondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("me-so-far")
        }
    }

    /// The numbers about PAI sit below the body, life and diary blocks, never above them.
    @ViewBuilder
    private func paiCard(_ presenter: MePresenter) -> some View {
        if let day = store.today, let pai = day.pai {
            let sessions = pai.sessions.map { " in \($0) session\($0 == 1 ? "" : "s")" }
            VStack(alignment: .leading, spacing: 8) {
                caption("PAI")
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        factCell(
                            FactCell(
                                id: "pai", value: "\(pai.messages)", unit: sessions, label: "messages to PAI",
                                color: MeColor.pai(dark: dark)))
                        if let morning = presenter.morningLine(day) {
                            Text(morning).font(PaiTypography.body.font).foregroundStyle(
                                PaiPalette.Semantic.textSecondary)
                        }
                    }
                }
                .accessibilityIdentifier("me-pai")
            }
        }
    }

    private struct FactCell: Identifiable {
        let id: String
        let value: String
        let unit: String?
        let label: String
        let color: Color
    }

    private func cellsFor(_ day: MeDay?, _ presenter: MePresenter, garmin: Bool) -> [FactCell] {
        guard let day else { return [] }
        var cells: [FactCell] = []
        if garmin, let body = day.body {
            if let slept = presenter.hoursMinutes(seconds: body.sleepSeconds) {
                let woke = presenter.clock(wire: body.wakeAt).map { " · woke \($0)" } ?? ""
                cells.append(
                    FactCell(id: "sleep", value: slept, unit: nil, label: "slept\(woke)", color: MeColor.sleep))
            }
            if let battery = body.bodyBatteryWake {
                cells.append(
                    FactCell(
                        id: "battery", value: "\(battery)", unit: nil, label: "body battery on waking",
                        color: MeColor.battery))
            }
        }
        if garmin, let activity = day.activities.last, let duration = presenter.duration(seconds: activity.durationS) {
            let started = presenter.clock(wire: activity.startAt).map { " · \($0)" } ?? ""
            cells.append(
                FactCell(
                    id: "movement", value: duration, unit: nil,
                    label: "\(activity.name ?? activity.type ?? "activity")\(started)",
                    color: MeColor.movement(dark: dark)))
        }
        return cells
    }

    private func factCell(_ cell: FactCell) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(cell.value)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(PaiPalette.Semantic.textStrong)
                if let unit = cell.unit {
                    Text(unit).font(PaiTypography.body.font).foregroundStyle(PaiPalette.Semantic.textSecondary)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(cell.color).frame(width: 8, height: 8)
                Text(cell.label)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private func week(_ overview: MeOverview, _ presenter: MePresenter) -> some View {
        let days = presenter.week(of: overview.days, todayKey: overview.today)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption("This week")
                Button("14 days ›") { showDays(overview.today) }
                    .font(PaiTypography.body.font)
                    .accessibilityIdentifier("me-week-open-days")
            }
            card {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(days) { day in
                        weekColumn(day, presenter, isToday: day.date == overview.today)
                    }
                }
            }
            .accessibilityIdentifier("me-week")
        }
    }

    private func weekColumn(_ day: MeDay, _ presenter: MePresenter, isToday: Bool) -> some View {
        let marks = presenter.marks(of: day.entries)
        return Button {
            showDays(day.date)
        } label: {
            VStack(spacing: 6) {
                Text(presenter.weekdayLetter(key: day.date))
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(isToday ? PaiPalette.primary400 : PaiPalette.Semantic.textMuted)
                Text(presenter.dayNumber(key: day.date))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Text(day.activities.prefix(2).compactMap(\.emoji).joined())
                    .font(.system(size: 14))
                    .frame(height: 18)
                VStack(spacing: 3) {
                    ForEach(Array(marks.faces.enumerated()), id: \.offset) { _, feel in FeelFace(feel: feel, size: 18) }
                    if marks.lock {
                        Image(systemName: "lock")
                            .font(.system(size: 11))
                            .foregroundStyle(MeColor.lock(dark: dark))
                    }
                }
                .frame(minHeight: 18, alignment: .top)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isToday ? PaiPalette.Semantic.insetBackground : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
                MeEntryCard(
                    item: MeDiaryItem(report: entry, waiting: false, refusal: nil), compact: true, presenter: presenter)
            }
        }
    }

    private func lookingBack(_ entry: SelfReport, _ presenter: MePresenter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Looking back")
            MeEntryCard(
                item: MeDiaryItem(report: entry, waiting: false, refusal: nil), compact: true, presenter: presenter)
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
