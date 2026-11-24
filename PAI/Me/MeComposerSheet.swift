import PAIKit
import SwiftUI
import UIKit

/// Where the composer writes: a new entry (the draft kept on the phone) or a change to a stored one.
enum MeComposerMode: Identifiable {
    case new
    case edit(SelfReport)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let report): "edit-\(report.id)"
        }
    }
}

/// The self-report composer. It never asks for anything: a face, a few words, or both. Send always
/// succeeds locally; the entry waits in the outbox when there is no network.
struct MeComposerSheet: View {
    let mode: MeComposerMode
    /// Seed for the face when the sheet opens from one of the faces on Today.
    var initialFeel: SelfReportFeel?

    @Environment(SelfReportStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var working = SelfReportDraft()
    @State private var timePopover = false
    @State private var sending = false
    @FocusState private var focused: Bool

    private let presenter = MePresenter()

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TextEditor(text: $working.text)
                .font(.system(size: 17))
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("me-composer-text")
            if working.isPrivate {
                Label {
                    Text("Private — agents see only the time and the face unless you say so")
                } icon: {
                    Image(systemName: "lock")
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(MeColor.lock(dark: scheme == .dark))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("me-composer-private-note")
            }
        }
        .background(PaiPalette.Semantic.panelBackground, ignoresSafeAreaEdges: .all)
        .safeAreaInset(edge: .bottom, spacing: 0) { toolbar }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: seed)
        .task { focused = true }
        .onChange(of: working) { _, value in
            if !isEditing { store.updateDraft { $0 = value } }
        }
        .accessibilityIdentifier("me-composer")
    }

    private func seed() {
        switch mode {
        case .new:
            working = store.draft
            if let initialFeel, working.feel == nil { working.feel = initialFeel.wire }
        case .edit(let report):
            working = SelfReportDraft(
                text: report.text ?? "", feel: report.feel?.wire, isPrivate: report.isPrivate, at: report.date)
        }
    }

    private var header: some View {
        HStack {
            Button(isEditing ? "Cancel" : "Close") { dismiss() }
                .accessibilityIdentifier("me-composer-close")
            Spacer()
            Button {
                timePopover = true
            } label: {
                HStack(spacing: 4) {
                    Text(timeLabel)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(PaiPalette.Semantic.raisedSurface, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("me-composer-time")
            .popover(isPresented: $timePopover) { timePicker.presentationCompactAdaptation(.popover) }
            Spacer()
            // Balances the Close button so the time chip sits in the middle.
            Text(isEditing ? "Cancel" : "Close").hidden()
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var timeLabel: String {
        guard let at = working.at else { return "Now · \(presenter.shortDay(date: Date()))" }
        return "\(presenter.shortDay(date: at)) \(presenter.clock(at))"
    }

    private var timePicker: some View {
        VStack(spacing: 8) {
            DatePicker(
                "When", selection: Binding(get: { working.at ?? Date() }, set: { working.at = $0 }),
                in: ...Date(), displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .environment(\.locale, ClockTime.pickerLocale)
            .environment(\.timeZone, presenter.calendar.timeZone)
            Button("Now") {
                working.at = nil
                timePopover = false
            }
        }
        .padding()
        .frame(minWidth: 320)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            ForEach(SelfReportFeel.allCases, id: \.wire) { feel in
                faceButton(feel)
            }
            Rectangle().fill(PaiPalette.Semantic.borderDefault).frame(width: 1, height: 28)
            privatePill
            Spacer(minLength: 0)
            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PaiPalette.Semantic.panelBackground)
        .overlay(alignment: .top) { Rectangle().fill(PaiPalette.Semantic.borderDefault).frame(height: 1) }
    }

    private func faceButton(_ feel: SelfReportFeel) -> some View {
        let selected = working.feel == feel.wire
        let color = MeColor.feel(feel, dark: scheme == .dark)
        return Button {
            working.feel = selected ? nil : feel.wire
        } label: {
            FeelFace(feel: feel, size: 34)
                .padding(3)
                .overlay(Circle().stroke(color.opacity(selected ? 0.35 : 0), lineWidth: 3))
                .opacity(working.feel == nil || selected ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(feel.spokenName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("me-composer-face-\(feel.wire ?? "other")")
    }

    private var privatePill: some View {
        let color = MeColor.lock(dark: scheme == .dark)
        return Button {
            working.isPrivate.toggle()
        } label: {
            Label("Private", systemImage: "lock")
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(working.isPrivate ? color : PaiPalette.Semantic.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(working.isPrivate ? color.opacity(0.14) : .clear, in: Capsule())
                .overlay(
                    Capsule().stroke(working.isPrivate ? color.opacity(0.55) : PaiPalette.surface600, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(working.isPrivate ? .isSelected : [])
        .accessibilityIdentifier("me-composer-private")
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(PaiPalette.primary500, in: Circle())
                .opacity(working.canSend && !sending ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!working.canSend || sending)
        .accessibilityLabel(isEditing ? "Save" : "Send")
        .accessibilityIdentifier("me-composer-send")
    }

    private func submit() {
        guard working.canSend else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch mode {
        case .new:
            let privately = working.isPrivate
            store.updateDraft { $0 = working }
            guard store.send() else { return }
            toasts.show(privately ? "Saved privately" : "Saved", kind: .success)
            dismiss()
        case .edit(let report):
            sending = true
            Task {
                let text = working.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let patch = SelfReportPatchBody(
                    text: text.isEmpty ? nil : text, clearText: text.isEmpty, feel: working.feel,
                    clearFeel: working.feel == nil, isPrivate: working.isPrivate,
                    at: working.at != report.date ? working.at.map(AlarmTime.wireString) : nil)
                let saved = await store.update(id: report.id, patch)
                sending = false
                if saved {
                    toasts.show("Saved", kind: .success)
                    dismiss()
                } else {
                    toasts.show(store.errorMessage ?? "Could not save", kind: .error)
                }
            }
        }
    }
}

extension MePresenter {
    /// "Tue 24 Nov" for a moment, on the zone's calendar.
    func shortDay(date: Date) -> String { shortDay(key: dayKey(date)) }
}
