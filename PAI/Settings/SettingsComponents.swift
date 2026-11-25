import PAIKit
import SwiftUI

/// A section whose header names whose settings it holds: "Input · This iPhone", "Dictation ·
/// Synced", "Defaults · Everyone". The tag is the one place "is this global?" is answered.
struct ScopedSection<Content: View>: View {
    let title: String
    let scope: SettingsScope
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            content
        } header: {
            Text("\(title) · \(scope.label)")
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

/// The registry keys of `keys` as rows, in the order given. A key the caller may not see, or the
/// server keeps off the screens, draws nothing.
struct RegistryRows: View {
    let store: SettingsRegistryStore
    let keys: [String]

    var body: some View {
        ForEach(store.fields(keys)) { field in
            RegistryRow(field: field, store: store)
        }
    }
}

/// One registry key as a row, chosen by what it holds. Labels, help and the cost warning are the
/// server's words, so this screen and the web's say the same; no bound is checked here, the
/// server answers a refused value with the rule it broke and the row shows it. Switches and
/// choices save on change and are put back when refused; text, numbers, lists and JSON save
/// with their own button and keep what was typed when refused.
struct RegistryRow: View {
    let field: SettingField
    let store: SettingsRegistryStore

    @Environment(ToastCenter.self) private var toasts
    @State private var draft = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            control
            if !field.help.isEmpty {
                Text(field.help)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if let warning = field.warning {
                Text(warning)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
            }
            if let problem {
                Text(problem)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
        .onAppear { draft = field.storedText }
        .onChange(of: field.storedText) { _, stored in draft = stored }
        .accessibilityIdentifier("setting-\(field.key)")
    }

    @ViewBuilder
    private var control: some View {
        switch field.control {
        case .toggle:
            Toggle(field.label, isOn: Binding(get: { field.isOn }, set: { save(.bool($0)) }))
        case .choice(let choices):
            choiceControl(choices)
        case .number:
            LabeledContent(field.label) { numberField }
            saveBar
        case .optionalNumber:
            Toggle(
                field.label,
                isOn: Binding(
                    get: { field.isNumberOn },
                    set: { on in save(on ? field.valueWhenTurnedOn : .null, optimistic: true) }))
            if field.isNumberOn {
                LabeledContent("Value") { numberField }
                saveBar
            }
        case .text:
            LabeledContent(field.label) {
                TextField("Not set", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commit)
            }
            saveBar
        case .list:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(PaiTypography.bodyEmphasized.font)
                TextField("One per line", text: $draft, axis: .vertical)
                    .lineLimit(2...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            saveBar
        case .json:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(PaiTypography.bodyEmphasized.font)
                TextField("{\"end_wait_s\": 2}", text: $draft, axis: .vertical)
                    .lineLimit(2...8)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            saveBar
        }
    }

    private func choiceControl(_ choices: [String]) -> some View {
        let binding = Binding(get: { field.choice }, set: { save(.string($0)) })
        return Group {
            if choices.count <= 3 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.label).font(PaiTypography.bodyEmphasized.font)
                    Picker(field.label, selection: binding) {
                        ForEach(choices, id: \.self) { Text(SettingField.choiceLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                Picker(field.label, selection: binding) {
                    ForEach(choices, id: \.self) { Text(SettingField.choiceLabel($0)).tag($0) }
                }
            }
        }
    }

    private var numberField: some View {
        TextField("0", text: $draft)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .onSubmit(commit)
    }

    /// Save and Discard appear only while the typed text differs from what is stored.
    @ViewBuilder
    private var saveBar: some View {
        if draft != field.storedText {
            HStack {
                Button("Save", action: commit)
                    .disabled(saving)
                    .accessibilityIdentifier("setting-save-\(field.key)")
                Spacer()
                Button("Discard", role: .cancel) {
                    draft = field.storedText
                    problem = nil
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func commit() {
        switch field.parse(draft) {
        case .failure(let failure):
            problem = failure.message
        case .success(let value):
            problem = nil
            save(value)
        }
    }

    private func save(_ value: SettingValue, optimistic: Bool? = nil) {
        saving = true
        Task {
            let saved = await store.update(field.key, to: value, optimistic: optimistic ?? field.savesOnChange)
            saving = false
            if !saved, let message = store.errorMessage {
                // A refused field keeps the typed text and names the rule beside it.
                if optimistic ?? field.savesOnChange { toasts.show(message, kind: .error) } else { problem = message }
            }
        }
    }
}

/// What a category page shows while the registry has not answered, or could not.
struct RegistryPlaceholder: View {
    let store: SettingsRegistryStore

    var body: some View {
        if !store.isLoaded {
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
    }
}

/// A category's icon square, as the list draws it.
struct CategoryIcon: View {
    let category: SettingsCategory

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(
                    Color(
                        red: Double((category.tintHex >> 16) & 0xFF) / 255,
                        green: Double((category.tintHex >> 8) & 0xFF) / 255,
                        blue: Double(category.tintHex & 0xFF) / 255))
            )
            .accessibilityHidden(true)
    }
}
