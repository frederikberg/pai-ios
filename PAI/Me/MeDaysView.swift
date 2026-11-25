import PAIKit
import SwiftUI

/// The last 14 days as columns, a row per kind of thing, every row printing its number. Colours
/// name what a row is; nothing here scores a day. A row whose source is not connected is not
/// drawn, and a day without a value leaves its cell blank.
struct MeDaysView: View {
    let store: MeOverviewStore
    let edit: (SelfReport) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var workedSheet: MeWorkedProject?
    @State private var showAllWorked = false
    @State private var showTasks = false

    private let gutter: CGFloat = 60
    private let sidePadding: CGFloat = 16
    private var dark: Bool { scheme == .dark }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if let overview = store.overview {
                    let width = proxy.size.width - sidePadding * 2
                    VStack(alignment: .leading, spacing: 18) {
                        titleRow(overview)
                        grid(overview, width: width)
                        detail(overview)
                    }
                    .padding(.horizontal, sidePadding)
                    .padding(.bottom, 32)
                } else if store.isLoading {
                    Text("Loading…").font(PaiTypography.body.font).foregroundStyle(PaiPalette.Semantic.textMuted)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    Text("Me could not be loaded.")
                        .font(PaiTypography.body.font).foregroundStyle(PaiPalette.Semantic.textMuted)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .fixtureScrollsToAnchor()
            .refreshable { await store.load() }
        }
        .sheet(item: $workedSheet) { project in WorkedSheet(project: project, presenter: store.presenter) }
    }

    // MARK: Title and paging

    private func titleRow(_ overview: MeOverview) -> some View {
        HStack {
            Text(store.presenter.rangeTitle(from: overview.days.first?.date ?? "", to: overview.days.last?.date ?? ""))
                .font(PaiTypography.screenTitle.font)
                .foregroundStyle(PaiPalette.Semantic.textStrong)
            Spacer()
            if store.canGoLater {
                Button("later ›") { Task { await store.later() } }
                    .accessibilityIdentifier("me-days-later")
            }
            Button("‹ earlier") { Task { await store.earlier() } }
                .accessibilityIdentifier("me-days-earlier")
        }
        .font(PaiTypography.panelTitle.font)
    }

    // MARK: Grid

    private func grid(_ overview: MeOverview, width: CGFloat) -> some View {
        let days = overview.days
        let cell = max(10, (width - gutter) / CGFloat(max(1, days.count)))
        let presenter = store.presenter
        let busiest = presenter.busiestDay(days)
        let selected = days.firstIndex { $0.date == store.selectedDate }
        let rows = MeLayout.gridRows(garminConnected: overview.sources.garminConnected)

        func row<Content: View>(
            _ label: String?, height: CGFloat, @ViewBuilder _ content: @escaping (MeDay) -> Content
        ) -> some View {
            HStack(spacing: 0) {
                gutterLabel(label).frame(width: gutter, height: height)
                ForEach(days) { day in
                    content(day)
                        .frame(width: cell, height: height)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await store.select(date: day.date) } }
                }
            }
        }

        @ViewBuilder
        func gridRow(_ kind: MeLayout.GridRow) -> some View {
            switch kind {
            case .diary:
                row("diary", height: 22) { day in diaryCell(day, presenter, cell: cell) }
            case .night:
                HStack(spacing: 0) {
                    nightGutter.frame(width: gutter, height: MePresenter.nightRowHeight)
                    ForEach(days) { day in
                        nightCell(day, presenter, cell: cell, isToday: day.date == overview.today)
                            .frame(width: cell, height: MePresenter.nightRowHeight)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await store.select(date: day.date) } }
                    }
                }
            case .sleepScore:
                row("sleep score", height: 15) { day in
                    numberCell(day.body?.sleepScore, color: PaiPalette.Semantic.textSecondary, size: 10)
                }
            case .battery:
                row("battery", height: 15) { day in
                    numberCell(day.body?.bodyBatteryWake, color: MeColor.battery, size: 10)
                }
            case .moved:
                row("moved", height: 22) { day in
                    Text(day.activities.prefix(2).compactMap(\.emoji).joined())
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.bottom, 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            case .messages:
                row("messages", height: 44) { day in messageCell(day, presenter, busiest: busiest, cell: cell) }
            case .agents:
                row("☾ agents", height: 14) { day in
                    Text(presenter.overnightLabel(minutes: day.pai?.overnightAgentMinutes) ?? "")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                }
            }
        }

        return VStack(alignment: .leading, spacing: 0) {
            row(nil, height: 34) { day in
                VStack(spacing: 0) {
                    Text(presenter.weekdayLetter(key: day.date))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(
                            day.date == overview.today ? PaiPalette.primary400 : PaiPalette.Semantic.textMuted)
                    Text(presenter.dayNumber(key: day.date))
                        .font(.system(size: 11, weight: day.date == store.selectedDate ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(
                            day.date == store.selectedDate
                                ? PaiPalette.Semantic.textStrong : PaiPalette.Semantic.textMuted
                        )
                        .padding(.bottom, 3)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(presenter.shortDay(key: day.date))
                .accessibilityAddTraits(.isButton)
            }
            ForEach(rows, id: \.self) { kind in gridRow(kind) }
        }
        .background(alignment: .topLeading) {
            if let selected {
                Rectangle()
                    .fill(PaiPalette.Semantic.insetBackground)
                    .frame(width: cell)
                    .offset(x: gutter + CGFloat(selected) * cell)
            }
        }
        .accessibilityIdentifier("me-days-grid")
    }

    private func gutterLabel(_ text: String?) -> some View {
        Text(text ?? "")
            .font(.system(size: 10))
            .foregroundStyle(PaiPalette.Semantic.textFaint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The night row's gutter marks the two hours its hairlines sit on.
    private var nightGutter: some View {
        ZStack(alignment: .topTrailing) {
            ForEach([0.0, 6.0], id: \.self) { hour in
                Text(hour == 0 ? "0:00" : "6:00")
                    .font(.system(size: 10))
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .padding(.trailing, 8)
                    .offset(y: CGFloat(MePresenter.nightY(hour: hour)) - 7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// One dot per entry, in the face's colour; a ring for an entry without a face and violet for
    /// a private one. Rows of three, six dots at most, in a cell of fixed height.
    private func diaryCell(_ day: MeDay, _ presenter: MePresenter, cell: CGFloat) -> some View {
        let dots = presenter.diaryDots(day.entries)
        let size = min(6, (cell - 3) / 3)
        let lines = stride(from: 0, to: dots.count, by: 3).map { Array(dots[$0..<min($0 + 3, dots.count)]) }
        return VStack(spacing: 1.5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 1.5) {
                    ForEach(Array(line.enumerated()), id: \.offset) { _, dot in dotView(dot, size: size) }
                }
            }
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private func dotView(_ dot: MeDiaryDot, size: CGFloat) -> some View {
        switch dot {
        case .face(let feel): Circle().fill(MeColor.feel(feel, dark: dark)).frame(width: size, height: size)
        case .noFace:
            Circle().stroke(PaiPalette.surface500, lineWidth: 1).frame(width: size, height: size)
        case .privateNoFace: Circle().fill(MeColor.lock(dark: dark)).frame(width: size, height: size)
        }
    }

    /// The night as one bar from bed to waking on a 21:00 to 11:00 axis, hairlines at midnight and 06:00.
    private func nightCell(_ day: MeDay, _ presenter: MePresenter, cell: CGFloat, isToday: Bool) -> some View {
        let bar = presenter.nightBar(day.body)
        let width = max(8, cell - 12)
        return ZStack(alignment: .topLeading) {
            ForEach([0.0, 6.0], id: \.self) { hour in
                Rectangle()
                    .fill(PaiPalette.Semantic.borderDefault)
                    .frame(height: 1)
                    .offset(y: CGFloat(MePresenter.nightY(hour: hour)))
            }
            if let bar {
                RoundedRectangle(cornerRadius: 3)
                    .fill(MeColor.sleep.opacity(isToday ? 0.5 : 0.9))
                    .frame(width: width, height: CGFloat(bar.height))
                    .offset(x: (cell - width) / 2, y: CGFloat(bar.top))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func numberCell(_ value: Int?, color: Color, size: CGFloat) -> some View {
        Text(value.map { "\($0)" } ?? "")
            .font(.system(size: size))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// A grey bar against the busiest day on screen, the count printed under it.
    private func messageCell(_ day: MeDay, _ presenter: MePresenter, busiest: Int, cell: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let pai = day.pai {
                UnevenRoundedRectangle(
                    topLeadingRadius: 3, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 3
                )
                .fill(PaiPalette.surface500)
                .frame(
                    width: max(8, cell - 12),
                    height: CGFloat(presenter.messageBarHeight(messages: pai.messages, busiest: busiest))
                )
                Text("\(pai.messages)")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 13)
            }
        }
    }

    // MARK: Day detail

    @ViewBuilder
    private func detail(_ overview: MeOverview) -> some View {
        if let day = store.selectedDetail {
            let presenter = store.presenter
            let tasks = store.selectedTasks
            let facts = presenter.facts(day: day, tasks: tasks, garmin: overview.sources.garminConnected)
            let ribbon = presenter.ribbon(day: day, tasks: tasks, now: Date())
            VStack(alignment: .leading, spacing: 12) {
                Text(presenter.longDay(key: day.date))
                    .font(PaiTypography.screenTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textStrong)
                if ribbon.hasData {
                    MeRibbonView(ribbon: ribbon)
                }
                factRows(facts, tasks: tasks, presenter: presenter)
                worked(day, presenter)
                if !day.entries.isEmpty {
                    Divider().overlay(PaiPalette.Semantic.borderDefault)
                    ForEach(day.entries) { entry in
                        MeEntryCard(
                            item: MeDiaryItem(report: entry, waiting: false, refusal: nil), presenter: presenter
                        )
                        .contextMenu { Button("Edit", systemImage: "pencil") { edit(entry) } }
                    }
                }
            }
            .meCard(padding: 16)
            .id(FixtureScrollAnchor.meDayDetail.rawValue)
            .accessibilityIdentifier("me-day-detail")
        }
    }

    /// One line per fact, a coloured dot first; the line about ticked tasks opens the list.
    @ViewBuilder
    private func factRows(_ facts: [MeFact], tasks: MeTasks?, presenter: MePresenter) -> some View {
        ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
            if fact.tone == .done, let tasks {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        showTasks.toggle()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            factLine(fact)
                            Image(systemName: showTasks ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(PaiPalette.Semantic.textFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showTasks {
                        ForEach(tasks.done, id: \.rowKey) { row in
                            HStack {
                                Text(row.kind == .task ? row.title : "🛒 \(row.size) \(row.title) items")
                                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                                Spacer()
                                Text(presenter.clock(wire: row.completedAt) ?? "")
                                    .monospacedDigit()
                                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                            }
                            .font(.system(size: 13))
                            .padding(.leading, 17)
                        }
                    }
                }
            } else {
                factLine(fact)
            }
        }
    }

    private func factLine(_ fact: MeFact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(MeColor.fact(fact.tone, dark: dark)).frame(width: 9, height: 9)
            Text(fact.text).font(.system(size: 15)).foregroundStyle(PaiPalette.Semantic.textPrimary)
        }
    }

    /// Agent time per project: a row each, the short ones behind one line.
    @ViewBuilder
    private func worked(_ day: MeDay, _ presenter: MePresenter) -> some View {
        let worked = presenter.workedOn(day.held)
        if !worked.shown.isEmpty || !worked.rest.isEmpty {
            Divider().overlay(PaiPalette.Semantic.borderDefault)
            Text("WORKED ON · AGENT TIME PER PROJECT")
                .font(PaiTypography.captionEmphasized.font).tracking(0.8)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            ForEach(showAllWorked ? worked.shown + worked.rest : worked.shown) { project in
                Button {
                    workedSheet = project
                } label: {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                            .lineLimit(1)
                        Text("· \(presenter.workedLine(project))")
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                    }
                    .font(.system(size: 14))
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let label = worked.restLabel {
                Button {
                    showAllWorked.toggle()
                } label: {
                    Text(showAllWorked ? "Fewer ⌃" : label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The topics a project held that day, with their summaries.
private struct WorkedSheet: View {
    let project: MeWorkedProject
    let presenter: MePresenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if project.phases.allSatisfy({ $0.summary == nil }) {
                    Text("No summaries for this day.").foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                ForEach(Array(project.phases.enumerated()), id: \.offset) { _, phase in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            [phase.title, presenter.roundedMinutes(phase.minutes)].compactMap { $0 }.joined(
                                separator: " · ")
                        )
                        .font(PaiTypography.panelTitle.font)
                        if let summary = phase.summary {
                            Text(summary).font(PaiTypography.body.font).foregroundStyle(
                                PaiPalette.Semantic.textSecondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
