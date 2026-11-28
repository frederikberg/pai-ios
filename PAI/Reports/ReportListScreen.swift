import PAIKit
import SwiftUI

/// The Reports app: the dynamic reports the agents published, newest first, a plain list. Swift
/// port of `ReportList.tsx`; a tap opens the report on top of this list.
struct ReportListScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store: ReportListStore?

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("reports-list-screen")
        .task {
            guard let client = environment.connection?.apiClient else { return }
            // Re-read on every return from a report: it may have been deleted meanwhile.
            let current = store ?? ReportListStore(api: client)
            store = current
            await current.load()
        }
    }

    @ViewBuilder
    private func content(_ store: ReportListStore) -> some View {
        if store.isLoading && store.reports.isEmpty {
            ProgressView()
        } else if let error = store.errorMessage, store.reports.isEmpty {
            VStack(spacing: 8) {
                Text(error)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if store.reports.isEmpty {
            Text("No reports yet. When a session publishes one, it shows up here.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        } else {
            List {
                ForEach(store.reports) { report in
                    Button {
                        environment.router.push(.report(id: report.id))
                    } label: {
                        ReportRow(report: report)
                    }
                    .accessibilityIdentifier("report-row-\(report.id)")
                }
                if store.hasMore {
                    Button("Older reports") { Task { await store.loadMore() } }
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
        }
    }
}

private struct ReportRow: View {
    let report: DynamicReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(report.title)
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .lineLimit(2)
            Text(subtitle)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .lineLimit(1)
            if let decisions = report.decisions, let label = decisions.label {
                Label(label, systemImage: decisions.hasOpen ? "circle.dashed" : "checkmark.circle")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(decisions.hasOpen ? PaiPalette.amber500 : PaiPalette.Semantic.textMuted)
                    .accessibilityIdentifier("report-decisions")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = IsoTimestamp.date(from: report.createdAt) {
            parts.append(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
        }
        if let session = report.sessionTitle, !session.isEmpty { parts.append(session) }
        return parts.joined(separator: " · ")
    }
}
