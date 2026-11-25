import PAIKit
import SwiftUI

/// A numeric keypad and the dots it fills, for a PIN of four to six digits. It only collects
/// digits; what they mean is the caller's.
struct PinPad: View {
    @Binding var digits: String
    let onSubmit: () -> Void

    private static let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]
    private let maxDigits = SleepPin.lengths.upperBound

    var body: some View {
        VStack(spacing: 24) {
            dots
            VStack(spacing: 12) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(row, id: \.self) { digit in key(digit) }
                    }
                }
                HStack(spacing: 12) {
                    Button(action: submit) {
                        Image(systemName: "checkmark")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!SleepPin.lengths.contains(digits.count))
                    .accessibilityLabel("Confirm")
                    .accessibilityIdentifier("pin-confirm")
                    key("0")
                    Button {
                        if !digits.isEmpty { digits.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title3)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Delete")
                    .accessibilityIdentifier("pin-delete")
                }
            }
            .frame(maxWidth: 320)
        }
    }

    private var dots: some View {
        HStack(spacing: 14) {
            ForEach(0..<maxDigits, id: \.self) { index in
                Circle()
                    .fill(index < digits.count ? PaiPalette.Semantic.textPrimary : Color.clear)
                    .overlay(Circle().stroke(PaiPalette.Semantic.borderStrong, lineWidth: 1))
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(digits.count) digits entered")
        .accessibilityIdentifier("pin-dots")
    }

    private func key(_ digit: String) -> some View {
        Button {
            if digits.count < maxDigits { digits.append(digit) }
        } label: {
            Text(digit)
                .font(.title2.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("pin-key-\(digit)")
    }

    private func submit() {
        guard SleepPin.lengths.contains(digits.count) else { return }
        onSubmit()
    }
}

/// Asks for the PIN and tells the caller it was right. The check is the caller's, so the same
/// sheet serves waking early, changing the window, changing the PIN and turning sleep mode off.
struct PinEntrySheet: View {
    let title: String
    var prompt = "Enter your PIN"
    let check: (String) -> SleepPinResult
    let onAccepted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var digits = ""
    @State private var message: String?
    @State private var wrong = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(prompt)
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                if let message {
                    Text(message)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                        .accessibilityIdentifier("pin-message")
                }
                PinPad(digits: $digits, onSubmit: submit)
                Spacer(minLength: 0)
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sensoryFeedback(.error, trigger: wrong)
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("pin-entry")
    }

    private func submit() {
        let pin = digits
        digits = ""
        switch check(pin) {
        case .accepted:
            dismiss()
            onAccepted(pin)
        case .wrong:
            wrong += 1
            message = "That is not the PIN"
        case .wait:
            wrong += 1
            message = "Wait a moment, then try again"
        }
    }
}

/// Asks for a new PIN twice. Nothing is kept until both entries agree.
struct PinCreateSheet: View {
    let title: String
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var digits = ""
    @State private var message: String?
    @State private var wrong = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(first == nil ? "Choose a PIN of 4 to 6 digits" : "Enter it again")
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                if let message {
                    Text(message)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                        .accessibilityIdentifier("pin-message")
                }
                PinPad(digits: $digits, onSubmit: submit)
                Spacer(minLength: 0)
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sensoryFeedback(.error, trigger: wrong)
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("pin-create")
    }

    private func submit() {
        let entered = digits
        digits = ""
        guard let first else {
            self.first = entered
            message = nil
            return
        }
        if entered == first {
            dismiss()
            onCreated(entered)
        } else {
            self.first = nil
            wrong += 1
            message = "The two entries differ. Start again."
        }
    }
}
