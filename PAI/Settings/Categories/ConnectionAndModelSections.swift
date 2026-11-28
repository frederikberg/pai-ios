import PAIKit
import SwiftUI

/// The services PAI calls and the keys it calls them with: models, speech, search and the Claude
/// login. One card per service, each with its address, where its key comes from, a status, what
/// uses it and a one-call test. A key is held encrypted on the server and never shown again.
struct ProvidersSections: View {
    let settings: SettingsStore

    var body: some View {
        ConnectionCards(
            settings: settings, kinds: [.model, .speech, .search, .subscription])
        RegistryPlaceholder(store: settings.registry)
        ScopedSection(
            title: "Billing", registry: settings.registry, keys: ["anthropic_cycle_day"],
            footer: "The day of the month Anthropic's billing cycle starts, which the spend lines count from."
        ) {
            RegistryRows(store: settings.registry, keys: ["anthropic_cycle_day"])
        }
    }
}

/// Services PAI reaches on its own, with a key the server holds so an agent can use them
/// unattended; MailVerdict's assistant signs in to it from its own screen instead.
struct IntegrationsSections: View {
    let settings: SettingsStore

    var body: some View {
        ConnectionCards(settings: settings, kinds: [.integration])
    }
}

/// The connections of some kinds as cards, read when the page opens.
struct ConnectionCards: View {
    let settings: SettingsStore
    let kinds: [ConnectionKind]

    private var store: ConnectionsStore { settings.connections }

    var body: some View {
        if store.connections == nil {
            Section {
                if let error = store.loadError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                } else {
                    ProgressView()
                }
            }
        }
        ForEach(store.connections(ofKinds: kinds)) { connection in
            ConnectionCard(connection: connection, settings: settings)
        }
    }
}

private struct ConnectionCard: View {
    let connection: ServiceConnection
    let settings: SettingsStore

    @State private var address = ""

    private var store: ConnectionsStore { settings.connections }

    var body: some View {
        ScopedSection(title: connection.label, footer: connection.note) {
            LabeledContent("Status") {
                Text(statusText)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityIdentifier("connection-status-\(connection.id)")
            if let url = connection.baseUrl {
                LabeledContent("Address") {
                    Text(url)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let part = connection.baseUrlParam { addressPart(part) }
            if let credential = connection.credential {
                keyRow(
                    title: keyTitle(credential), secret: credential.secret, set: credential.set,
                    updatedAt: credential.updatedAt)
            }
            ForEach(connection.extra, id: \.secret) { extra in
                keyRow(title: extra.label, secret: extra.secret, set: extra.set, updatedAt: extra.updatedAt)
            }
            if connection.testable { testRow }
            if !connection.usedBy.isEmpty {
                LabeledContent("Used by") {
                    Text(connection.usedBy.map(\.label).joined(separator: ", "))
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let spend = spendText {
                LabeledContent("This cycle", value: spend)
            }
        }
        .onAppear { address = connection.baseUrlParam?.value ?? "" }
    }

    private func keyTitle(_ credential: ConnectionCredential) -> String { "API key" }

    /// The key field of a secret, its state taken from the list so a key set elsewhere shows here,
    /// and the list read again when a save or a clear here changes it.
    private func keyRow(title: String, secret: String, set: Bool, updatedAt: String?) -> some View {
        let field = settings.keyField(forSecret: secret)
        let known = SecretStatus(set: set, updatedAt: updatedAt)
        return SecretField(title: title, identifier: "key-\(secret)", field: field)
            .onAppear { if field.status != known { field.applyStatus(known) } }
            .onChange(of: known) { _, next in if field.status != next { field.applyStatus(next) } }
            .onChange(of: field.status?.set) { _, now in
                if now != set { Task { await store.load() } }
            }
    }

    private func addressPart(_ part: ConnectionAddressPart) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Product id") {
                TextField("From the deployment", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            if address != (part.value ?? "") {
                Button("Save") { Task { await store.setAddressPart(address, of: connection) } }
                    .buttonStyle(.borderless)
            }
            if let error = store.addressError {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
    }

    @ViewBuilder
    private var testRow: some View {
        HStack {
            Button(store.testing.contains(connection.id) ? "Testing…" : "Test") {
                Task { await store.test(connection) }
            }
            .disabled(store.testing.contains(connection.id))
            .accessibilityIdentifier("connection-test-\(connection.id)")
            Spacer()
            if let result = store.tests[connection.id] {
                Text(result.ok ? "Works · \(result.latencyMs) ms" : (result.message ?? "Failed"))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(result.ok ? PaiPalette.Semantic.textMuted : PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.trailing)
            }
        }
        if let error = store.testError[connection.id] {
            Text(error)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
        }
    }

    private var statusText: String {
        let base: String
        switch connection.status {
        case .ok: base = "Working"
        case .noKey: base = "No key"
        case .tripped: base = "Paused"
        case .failing: base = "Failing"
        case .unrecognized(let raw): base = raw
        }
        guard let detail = connection.statusDetail, !detail.isEmpty else { return base }
        return "\(base): \(detail)"
    }

    private var statusColor: Color {
        switch connection.status {
        case .ok: PaiPalette.Semantic.textMuted
        case .noKey: PaiPalette.Semantic.warningText
        case .tripped, .failing: PaiPalette.Semantic.errorText
        case .unrecognized: PaiPalette.Semantic.textMuted
        }
    }

    private var spendText: String? {
        guard let spend = connection.spend, let calls = spend.calls, calls > 0 else { return nil }
        let cost = spend.costUsd.map { "$" + $0.formatted(.number.precision(.fractionLength(2))) }
        return [cost, "\(calls) calls"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Which model answers each part of PAI: one row per feature with its default and fallback, and the
/// line under it saying what a call would do now.
struct ModelsSections: View {
    let settings: SettingsStore
    @State private var editing: ModelFeature?

    private var store: ModelRoutesStore { settings.modelRoutes }

    var body: some View {
        if store.features == nil {
            Section {
                if let error = store.loadError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                } else {
                    ProgressView()
                }
            }
        }
        group("Memory", "memory")
        group("Sessions and voice", "sessions")
        RegistryPlaceholder(store: settings.registry)
        if settings.registry.field("message_review_enabled") != nil {
            ScopedSection(title: "Message review", registry: settings.registry, keys: ["message_review_enabled"]) {
                RegistryRows(store: settings.registry, keys: ["message_review_enabled"])
            }
        }
        ScopedSection(
            title: "Memory, advanced", registry: settings.registry,
            keys: ["turn_summary_history_count", "turn_summary_history_tokens"],
            footer: "How much earlier turns a summary is given to read."
        ) {
            RegistryRows(
                store: settings.registry, keys: ["turn_summary_history_count", "turn_summary_history_tokens"])
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ id: String) -> some View {
        let features = store.features(inGroup: id)
        if !features.isEmpty {
            ScopedSection(title: title) {
                ForEach(features) { feature in
                    row(feature)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ feature: ModelFeature) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(feature.label)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            Text(feature.nowText)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        if feature.editable {
            Button {
                editing = feature
            } label: {
                HStack {
                    content
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("model-row-\(feature.id)")
            // On the row's own button, with its own binding: a sheet hung on a container is
            // presented once per row it holds.
            .sheet(
                item: Binding(
                    get: { editing?.id == feature.id ? editing : nil },
                    set: { if $0 == nil { editing = nil } })
            ) { feature in
                ModelRouteSheet(feature: feature, store: store)
            }
        } else {
            content.accessibilityIdentifier("model-row-\(feature.id)")
        }
    }
}

/// One feature's default and fallback: a provider, a model and an effort for each, with only what
/// the server lists for that slot on offer. A refusal (a provider with no key) is shown as the
/// server words it.
private struct ModelRouteSheet: View {
    let feature: ModelFeature
    let store: ModelRoutesStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModelRouteDraft

    init(feature: ModelFeature, store: ModelRoutesStore) {
        self.feature = feature
        self.store = store
        _draft = State(initialValue: ModelRouteDraft(feature: feature))
    }

    var body: some View {
        NavigationStack {
            Form {
                stepSection(title: "Default", forFallback: false)
                if draft.offersFallback {
                    Section {
                        Toggle(
                            "Fallback",
                            isOn: Binding(get: { draft.fallbackStep != nil }, set: { draft.setFallback(enabled: $0) })
                        )
                        .accessibilityIdentifier("model-fallback-toggle")
                    } footer: {
                        Text("Answers when the default cannot.")
                    }
                    if draft.fallbackStep != nil { stepSection(title: "Fallback", forFallback: true) }
                }
                if let error = store.saveError {
                    Section {
                        Text(error)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                            .accessibilityIdentifier("model-save-error")
                    }
                }
            }
            .paiListBackground()
            .navigationTitle(feature.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await store.save(feature, draft.update) { dismiss() }
                        }
                    }
                    .disabled(store.isSaving)
                    .accessibilityIdentifier("model-save")
                }
            }
            .onAppear { store.clearSaveError() }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func stepSection(title: String, forFallback: Bool) -> some View {
        let step = forFallback ? draft.fallbackStep : draft.defaultStep
        if let step {
            Section(title) {
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { step.provider }, set: { draft.chooseProvider($0, forFallback: forFallback) })
                ) {
                    ForEach(draft.providers(forFallback: forFallback), id: \.self) {
                        Text(ModelFeature.providerName($0)).tag($0)
                    }
                }
                Picker(
                    "Model",
                    selection: Binding(
                        get: { step.model }, set: { draft.chooseModel($0, forFallback: forFallback) })
                ) {
                    ForEach(draft.models(provider: step.provider, forFallback: forFallback), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                let efforts = draft.efforts(provider: step.provider, model: step.model, forFallback: forFallback)
                if efforts.compactMap({ $0 }).count > 0 {
                    Picker(
                        "Effort",
                        selection: Binding(
                            get: { step.effort }, set: { draft.chooseEffort($0, forFallback: forFallback) })
                    ) {
                        ForEach(efforts, id: \.self) {
                            Text($0.map { CreateSessionStore.effortLevelLabels[$0] ?? $0 } ?? "None").tag($0)
                        }
                    }
                }
            }
        }
    }
}
