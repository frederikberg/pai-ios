import PAIKit
import SwiftUI

/// The last 14 days as small multiples: a column per day, a row per kind of thing. Colours name
/// what a row is; nothing here scores a day. A row whose source is not connected is not drawn.
struct MeDaysView: View {
    let store: MeOverviewStore
    let edit: (SelfReport) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var heldSheet: MeHeld?

    private let gap: CGFloat = 2
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
            .refreshable { await store.load() }
        }
        .sheet(item: $heldSheet) { held in HeldSheet(held: held, presenter: store.presenter) }
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
        let cell = max(10, (width - gap * CGFloat(days.count - 1)) / CGFloat(max(1, days.count)))
        let presenter = store.presenter
        let garmin = overview.sources.garminConnected
        let selected = days.firstIndex { $0.date == store.selectedDate }

        func cells<Content: View>(height: CGFloat, @ViewBuilder _ content: @escaping (MeDay) -> Content) -> some View {
            HStack(spacing: gap) {
                ForEach(days) { day in
                    content(day)
                        .frame(width: cell, height: height)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await store.select(date: day.date) } }
                }
            }
        }

        @ViewBuilder
        func gridRow(_ row: MeLayout.GridRow) -> some View {
            switch row {
            case .diary:
                rowCaption("Diary", color: PaiPalette.amber400, source: "your words · blank = nothing written")
                cells(height: 42) { day in diaryCell(day, presenter) }
            case .sleep:
                rowCaption("Sleep", color: MeColor.sleep, source: "hours · Garmin")
                cells(height: 58) { day in sleepCell(day, presenter) }
            case .bodyBattery:
                rowCaption("Body battery on waking", color: MeColor.battery, source: "0–100 · Garmin")
                batteryRow(days, cell: cell, today: overview.today, selected: selected)
            case .movement:
                rowCaption("Movement", color: MeColor.movement(dark: dark), source: "activities · Garmin")
                cells(height: 28) { day in
                    Text(day.activities.prefix(2).compactMap(\.emoji).joined()).font(.system(size: 13))
                        .minimumScaleFactor(0.6)
                }
            case .calendar:
                rowCaption("Calendar", color: PaiPalette.green500, source: "events · titles in the day")
                cells(height: 22) { day in calendarCell(day) }
            case .pai:
                rowCaption("PAI", color: MeColor.pai(dark: dark), source: "your messages · ☾ agents ran overnight")
                cells(height: 52) { day in paiCell(day, presenter) }
            }
        }

        return VStack(alignment: .leading, spacing: 14) {
            cells(height: 38) { day in
                VStack(spacing: 2) {
                    Text(presenter.weekdayLetter(key: day.date))
                        .font(PaiTypography.captionEmphasized.font)
                        .foregroundStyle(
                            day.date == overview.today ? PaiPalette.primary400 : PaiPalette.Semantic.textMuted)
                    Text(presenter.dayNumber(key: day.date))
                        .font(.system(size: 11, weight: day.date == store.selectedDate ? .bold : .regular))
                        .foregroundStyle(
                            day.date == store.selectedDate
                                ? PaiPalette.Semantic.textStrong : PaiPalette.Semantic.textMuted)
                }
            }
            ForEach(
                MeLayout.gridRows(garminConnected: garmin, calendarConnected: overview.sources.calendarConnected),
                id: \.self
            ) { row in
                gridRow(row)
            }
        }
        .background(alignment: .topLeading) {
            if let selected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PaiPalette.Semantic.insetBackground)
                    .frame(width: cell)
                    .offset(x: CGFloat(selected) * (cell + gap))
            }
        }
        .accessibilityIdentifier("me-days-grid")
    }

    private func rowCaption(_ name: String, color: Color, source: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).font(PaiTypography.bodyEmphasized.font).foregroundStyle(PaiPalette.Semantic.textPrimary)
            Spacer(minLength: 8)
            Text(source)
                .font(.system(size: 11))
                .foregroundStyle(PaiPalette.Semantic.textFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.top, 4)
    }

    private func diaryCell(_ day: MeDay, _ presenter: MePresenter) -> some View {
        let marks = presenter.marks(of: day.entries)
        return VStack(spacing: 2) {
            ForEach(Array(marks.faces.enumerated()), id: \.offset) { _, feel in FeelFace(feel: feel, size: 18) }
            if marks.more > 0 {
                Text("+\(marks.more)").font(.system(size: 9)).foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if marks.lock {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(MeColor.lock(dark: dark))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// A dot per event, at most three: the titles are in the day's detail.
    private func calendarCell(_ day: MeDay) -> some View {
        VStack(spacing: 3) {
            ForEach(0..<min(3, day.events.count), id: \.self) { _ in
                Circle().fill(PaiPalette.green500.opacity(0.85)).frame(width: 6, height: 6)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func sleepCell(_ day: MeDay, _ presenter: MePresenter) -> some View {
        let seconds = day.body?.sleepSeconds
        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            if let height = presenter.sleepBarHeight(seconds: seconds) {
                if day.date == store.selectedDate, let label = presenter.sleepHoursLabel(seconds: seconds) {
                    Text(label).font(.system(size: 10)).foregroundStyle(PaiPalette.Semantic.textSecondary)
                }
                UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                    .fill(MeColor.sleep.opacity(day.final ? 0.9 : 0.45))
                    .frame(height: min(52, height))
            } else {
                Text("–").font(.system(size: 11)).foregroundStyle(PaiPalette.surface600)
            }
        }
    }

    private func batteryRow(_ days: [MeDay], cell: CGFloat, today: String, selected: Int?) -> some View {
        let color = MeColor.battery
        let height: CGFloat = 44
        let step = cell + gap
        return Canvas { context, size in
            func point(_ index: Int, _ value: Int) -> CGPoint {
                CGPoint(
                    x: CGFloat(index) * step + cell / 2,
                    y: 6 + (height - 12) * (1 - CGFloat(max(0, min(100, value))) / 100))
            }
            var line = Path()
            var previous: Int?
            for (index, day) in days.enumerated() {
                guard let value = day.body?.bodyBatteryWake else {
                    previous = nil
                    continue
                }
                let here = point(index, value)
                if previous != nil { line.addLine(to: here) } else { line.move(to: here) }
                previous = index
            }
            context.stroke(line, with: .color(color.opacity(0.55)), lineWidth: 1.6)
            for (index, day) in days.enumerated() {
                guard let value = day.body?.bodyBatteryWake else { continue }
                let center = point(index, value)
                let dot = Path(ellipseIn: CGRect(x: center.x - 2.6, y: center.y - 2.6, width: 5.2, height: 5.2))
                if day.date == today && !day.final {
                    context.stroke(dot, with: .color(color), lineWidth: 1.4)
                } else {
                    context.fill(dot, with: .color(color))
                }
            }
        }
        .frame(width: step * CGFloat(days.count) - gap, height: height)
        .accessibilityHidden(true)
    }

    private func paiCell(_ day: MeDay, _ presenter: MePresenter) -> some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            if let pai = day.pai {
                if (pai.overnightAgentMinutes ?? 0) > 0 {
                    Text("☾").font(.system(size: 11)).foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                    .fill(MeColor.pai(dark: dark).opacity(0.85))
                    .frame(height: presenter.paiBarHeight(messages: pai.messages, cap: 40))
            }
        }
    }

    // MARK: Day detail

    @ViewBuilder
    private func detail(_ overview: MeOverview) -> some View {
        if let day = store.selectedDetail {
            let presenter = store.presenter
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(presenter.longDay(key: day.date))
                        .font(PaiTypography.screenTitle.font)
                        .foregroundStyle(PaiPalette.Semantic.textStrong)
                    Spacer()
                }
                factRows(bodyFacts(day, presenter, garmin: overview.sources.garminConnected))
                if !day.entries.isEmpty {
                    Divider().overlay(PaiPalette.Semantic.borderDefault)
                    ForEach(day.entries) { entry in
                        MeEntryCard(
                            item: MeDiaryItem(report: entry, waiting: false, refusal: nil), presenter: presenter
                        )
                        .contextMenu { Button("Edit", systemImage: "pencil") { edit(entry) } }
                    }
                }
                let pai = paiFacts(day, presenter)
                if !pai.isEmpty {
                    Divider().overlay(PaiPalette.Semantic.borderDefault)
                    factRows(pai)
                }
                if !day.held.isEmpty {
                    Divider().overlay(PaiPalette.Semantic.borderDefault)
                    Text("WHAT THE DAY HELD")
                        .font(PaiTypography.captionEmphasized.font).tracking(0.8)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    FlowChips(items: day.held) { held in
                        Button {
                            heldSheet = held
                        } label: {
                            Text(
                                [held.title, presenter.roundedMinutes(held.totalMinutes)].compactMap { $0 }.joined(
                                    separator: " · ")
                            )
                            .font(PaiTypography.body.font)
                            .foregroundStyle(PaiPalette.Semantic.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(PaiPalette.Semantic.insetBackground, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(PaiPalette.Semantic.borderDefault, lineWidth: 1))
            .accessibilityIdentifier("me-day-detail")
        }
    }

    private struct Fact { let text: String; let color: Color }

    private func factRows(_ facts: [Fact]) -> some View {
        ForEach(facts, id: \.text) { fact in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(fact.color).frame(width: 9, height: 9)
                Text(fact.text).font(.system(size: 15)).foregroundStyle(PaiPalette.Semantic.textPrimary)
            }
        }
    }

    /// Sleep and movement: the body and life lines, first in the card.
    private func bodyFacts(_ day: MeDay, _ presenter: MePresenter, garmin: Bool) -> [Fact] {
        var facts: [Fact] = []
        if garmin, let body = day.body, let slept = presenter.hoursMinutes(seconds: body.sleepSeconds) {
            var text = "Slept \(slept)"
            if let woke = presenter.clock(wire: body.wakeAt) { text += ", woke \(woke)" }
            if let battery = body.bodyBatteryWake { text += " · battery \(battery)" }
            facts.append(Fact(text: text, color: MeColor.sleep))
        }
        if garmin {
            for activity in day.activities {
                let parts = [
                    "\(activity.emoji ?? "") \(activity.name?.capitalized ?? activity.type ?? "Activity")",
                    presenter.clock(wire: activity.startAt), presenter.duration(seconds: activity.durationS),
                    presenter.kilometres(meters: activity.distanceM),
                ].compactMap { $0 }
                facts.append(Fact(text: parts.joined(separator: " · "), color: MeColor.movement(dark: dark)))
            }
        }
        for event in day.events {
            facts.append(Fact(text: presenter.eventLine(event), color: PaiPalette.green500))
        }
        return facts
    }

    /// The numbers about PAI, below the diary entries: first and last message, the morning
    /// measure, the day's messages and the agents' overnight work.
    private func paiFacts(_ day: MeDay, _ presenter: MePresenter) -> [Fact] {
        guard let pai = day.pai else { return [] }
        var facts: [Fact] = []
        var first = [String]()
        if let at = presenter.clock(wire: pai.firstMessageAt) { first.append("First PAI message \(at)") }
        if let at = presenter.clock(wire: pai.lastMessageAt) { first.append("last \(at)") }
        if !first.isEmpty { facts.append(Fact(text: first.joined(separator: ", "), color: MeColor.lock(dark: dark))) }
        if let minutes = day.wakeToFirstMessageMin {
            facts.append(Fact(text: "\(minutes) min from waking to the first message", color: MeColor.lock(dark: dark)))
        }
        var line = "\(pai.messages) messages"
        if let sessions = pai.sessions { line += " in \(sessions) sessions" }
        if let minutes = pai.overnightAgentMinutes, minutes > 0, let hours = presenter.roundedMinutes(minutes) {
            line += " · agents ran \(hours) overnight"
        }
        facts.append(Fact(text: line, color: MeColor.pai(dark: dark)))
        return facts
    }
}

/// The phases a project held that day, with their summaries.
private struct HeldSheet: View {
    let held: MeHeld
    let presenter: MePresenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if held.phases.isEmpty {
                    Text("No summaries for this day.").foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                ForEach(held.phases, id: \.name) { phase in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            [phase.name, presenter.roundedMinutes(phase.minutes)].compactMap { $0 }.joined(
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
            .navigationTitle(held.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Chips that wrap onto further lines.
private struct FlowChips<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 8) { ForEach(items) { content($0) } }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.maxX, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in rows.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat, maxX: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, y + rowHeight, maxX)
    }
}
