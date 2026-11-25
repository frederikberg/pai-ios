import PAIKit
import SwiftUI

enum MeTab: String, CaseIterable, Identifiable {
    case today = "Today"
    case days = "14 days"
    case diary = "Diary"
    var id: String { rawValue }

    init?(fixtureName: String?) {
        switch fixtureName {
        case "today": self = .today
        case "days": self = .days
        case "diary": self = .diary
        default: return nil
        }
    }

    var factName: String {
        switch self {
        case .today: "today"
        case .days: "days"
        case .diary: "diary"
        }
    }
}

/// The Me app: one screen about the person's own wellbeing, three views under a segmented control.
/// Blank means nothing was written, and the screen says so rather than drawing a zero.
struct MeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SelfReportStore.self) private var reports
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = MeTab.today
    @State private var overview: MeOverviewStore?
    @State private var composer: MeComposerMode?
    @State private var composerFeel: SelfReportFeel?
    @State private var selectedDiaryEntry: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(MeTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityIdentifier("me-tabs")
            if let overview {
                switch tab {
                case .today:
                    MeTodayView(store: overview, write: write, showDays: showDays, showDiary: { tab = .diary })
                case .days:
                    MeDaysView(store: overview, edit: edit)
                case .diary:
                    MeDiaryView(overview: overview, write: { write(nil) }, edit: edit)
                }
            } else {
                Spacer()
                Text("Loading…").font(PaiTypography.body.font).foregroundStyle(PaiPalette.Semantic.textMuted)
                Spacer()
            }
        }
        .paiScreenBackground()
        .navigationTitle("Me")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $composer) { mode in
            MeComposerSheet(mode: mode, initialFeel: composerFeel)
        }
        .task {
            if overview == nil, let client = environment.connection?.apiClient {
                overview = MeOverviewStore(api: client)
                #if DEBUG
                    if PaiFixtureLaunch.isEnabled() { applyFixtureLaunch() }
                #endif
            }
            await overview?.load()
        }
        .onChange(of: reports.savedVersion) { _, _ in Task { await overview?.load() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await overview?.load() } }
        }
        .fixtureFact("meTab", tab.factName)
        .fixtureFact("meOverviewDays", "\(overview?.overview?.days.count ?? 0)")
    }

    private func write(_ feel: SelfReportFeel?) {
        composerFeel = feel
        composer = .new
    }

    private func edit(_ report: SelfReport) {
        composer = .edit(report)
    }

    private func showDays(_ date: String) {
        tab = .days
        Task { await overview?.select(date: date) }
    }

    #if DEBUG
        private func applyFixtureLaunch() {
            if let named = MeTab(fixtureName: PaiFixtureLaunch.requestedMeTab()) { tab = named }
            if let offset = PaiFixtureLaunch.requestedMeDayOffset(),
                let key = overview?.presenter.shift(key: overview?.presenter.dayKey(Date()) ?? "", byDays: -offset)
            {
                overview?.selectedDate = key
            }
            if PaiFixtureLaunch.opensMeComposer() {
                reports.updateDraft {
                    $0 = SelfReportDraft(
                        text: "Long call tonight, still thinking about it. Not bad, just a lot.", feel: "okay",
                        isPrivate: true)
                }
                composer = .new
            }
        }
    #endif
}
