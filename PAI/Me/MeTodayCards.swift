import PAIKit
import SwiftUI

extension View {
    /// The Me cards' chrome: padded, raised, rounded, hairline border.
    func meCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(PaiPalette.Semantic.borderDefault, lineWidth: 1))
    }
}

/// A small uppercase label over a group of rows.
private struct GroupCaption: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

/// The Todoist card of Today, read-only: appointments that are fixed, what is left, what was
/// ticked. A row opens Todoist; nothing here changes a task.
struct MeTodayCardView: View {
    let card: MeTodayCard
    let isRefreshing: Bool
    let refresh: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var showAllOpen = false
    @State private var showAllDone = false

    /// Rows a group shows before "n more".
    private let shownRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let line = card.countLine {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .padding(.top, 3)
            }
            if !card.fixed.isEmpty {
                GroupCaption(title: "Fixed")
                ForEach(Array(card.fixed.enumerated()), id: \.offset) { _, row in fixedRow(row) }
            }
            if !card.open.isEmpty {
                GroupCaption(title: "To come")
                let rows = showAllOpen ? card.open : Array(card.open.prefix(shownRows))
                ForEach(rows, id: \.id) { row in openRow(row) }
                more(card.open.count - rows.count, expanded: $showAllOpen)
            }
            if !card.done.isEmpty {
                GroupCaption(title: "Done")
                let rows = showAllDone ? card.done : Array(card.done.prefix(shownRows))
                ForEach(rows, id: \.key) { row in doneRow(row) }
                more(card.done.count - rows.count, expanded: $showAllDone)
            }
            if let footer = card.footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .padding(.top, 10)
                    .accessibilityIdentifier("me-tasks-footer")
            }
        }
        .meCard()
        .accessibilityIdentifier("me-tasks")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("TODAY")
                .font(PaiTypography.captionEmphasized.font)
                .tracking(0.8)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh tasks")
            .accessibilityIdentifier("me-tasks-refresh")
            Button {
                open(MeTodoistLink.today)
            } label: {
                Text("Open Todoist ↗")
                    .font(.system(size: 13))
                    .foregroundStyle(PaiPalette.primary400)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("me-tasks-open-todoist")
        }
    }

    private func rowFrame<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(PaiPalette.Semantic.borderDefault.opacity(0.6)).frame(height: 0.5)
            }
    }

    private func fixedRow(_ row: MeTodayCard.Fixed) -> some View {
        rowFrame {
            HStack(spacing: 8) {
                Text(row.time ?? "all day")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(minWidth: 40, alignment: .leading)
                Circle().fill(MeColor.calendar).frame(width: 8, height: 8)
                titleWithSuffix(row.title, row.suffix)
            }
        }
    }

    private func openRow(_ row: MeTodayCard.Open) -> some View {
        Button {
            open(MeTodoistLink.task(id: row.id))
        } label: {
            rowFrame {
                HStack(spacing: 10) {
                    Circle().stroke(PaiPalette.surface500, lineWidth: 1.5).frame(width: 15, height: 15)
                    titleWithSuffix(row.title, row.suffix)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private func doneRow(_ row: MeTodayCard.Done) -> some View {
        rowFrame {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(MeColor.done)
                Text(row.title)
                    .font(.system(size: 14))
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(row.time)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
    }

    private func titleWithSuffix(_ title: String, _ suffix: String?) -> some View {
        var text = AttributedString(title)
        text.foregroundColor = PaiPalette.Semantic.textPrimary
        if let suffix {
            var tail = AttributedString(" · \(suffix)")
            tail.foregroundColor = PaiPalette.Semantic.textMuted
            text += tail
        }
        return Text(text).font(.system(size: 14)).lineLimit(2)
    }

    @ViewBuilder
    private func more(_ hidden: Int, expanded: Binding<Bool>) -> some View {
        if hidden > 0 || expanded.wrappedValue {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                Text(expanded.wrappedValue ? "Fewer ⌃" : "\(hidden) more ⌄")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Opens the Todoist app, or its web page when the app is not installed.
    private func open(_ link: MeTodoistLink) {
        guard let app = URL(string: link.app), let web = URL(string: link.web) else { return }
        openURL(app) { accepted in
            if !accepted { openURL(web) }
        }
    }
}

/// The Plan card: what was agreed for the day, in his words, folded to four lines.
struct MePlanCardView: View {
    let card: MePlanCard
    @State private var expanded = false
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private let collapsedLines = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("PLAN")
                    .font(PaiTypography.captionEmphasized.font)
                    .tracking(0.8)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Spacer()
                if let appetite = card.appetite, !appetite.isEmpty {
                    Text(appetite)
                        .font(.system(size: 13))
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(PaiPalette.Semantic.insetBackground, in: Capsule())
                }
            }
            planText
                .lineLimit(expanded ? nil : collapsedLines)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    planText
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
                }
            if expanded || fullHeight > shownHeight + 1 {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Less ⌃" : "Whole plan ⌄")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PaiPalette.primary400)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me-plan-toggle")
            }
            if card.agreed != nil || card.progress != nil {
                VStack(alignment: .leading, spacing: 1) {
                    if let agreed = card.agreed { Text(agreed) }
                    if let progress = card.progress { Text(progress) }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .padding(.top, 2)
            }
        }
        .meCard()
        .accessibilityIdentifier("me-plan")
    }

    private var planText: some View {
        Text(card.text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .foregroundStyle(PaiPalette.Semantic.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The body lines under the ribbon: sleep, battery and the latest activity, one line each, a
/// coloured dot first. A line without data is not drawn.
struct MeBodyCardView: View {
    let lines: MeBodyLines
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(lines.sleep, color: MeColor.sleep)
            line(lines.battery, color: MeColor.battery)
            line(lines.movement, color: MeColor.movement(dark: scheme == .dark))
        }
        .meCard(padding: 12)
        .accessibilityIdentifier("me-body")
    }

    @ViewBuilder
    private func line(_ runs: [MeTextRun], color: Color) -> some View {
        if !runs.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(attributed(runs))
            }
        }
    }

    private func attributed(_ runs: [MeTextRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            piece.font = run.strong ? Font.system(size: 15, weight: .semibold) : Font.system(size: 12.5)
            piece.foregroundColor = run.strong ? PaiPalette.Semantic.textStrong : PaiPalette.Semantic.textMuted
            result += piece
        }
        return result
    }
}
