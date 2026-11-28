import PAIKit
import SwiftUI

/// Renders `ToastCenter`'s queue above everything else, bottom-anchored — the one place a toast
/// mounts, matching the web's single `ToastContainer`. Nothing existed here before this; every
/// failure the session actions menu can hit needed somewhere to land other than inline text in
/// whichever view happened to cause it.
///
/// A sheet covers the root's overlay, so a sheet whose changes are said in a toast mounts one of
/// its own. Only the root's stands above what a screen keeps at the bottom (`clearsBottomBars`):
/// those bars lie under a sheet with the rest of the screen.
struct ToastOverlay: View {
    let toasts: ToastCenter
    var clearsBottomBars = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(toasts.toasts) { toast in
                ToastRow(toast: toast, onDismiss: { toasts.dismiss(toast.id) })
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12 + (clearsBottomBars ? toasts.bottomBarHeight : 0))
        .animation(.default, value: toasts.toasts.map(\.id))
        .allowsHitTesting(!toasts.toasts.isEmpty)
    }
}

private struct ToastRow: View {
    let toast: ToastMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(PaiTypography.body.font)
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer(minLength: 0)

            if let action = toast.action {
                Button(action.label) {
                    action.handler()
                    onDismiss()
                }
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.primary400)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 2)
        .accessibilityIdentifier("toast-\(identifierSuffix)")
    }

    private var backgroundColor: Color {
        switch toast.kind {
        case .error: PaiPalette.red600
        case .success: PaiPalette.green600
        case .info: PaiPalette.surface800
        }
    }

    private var identifierSuffix: String {
        switch toast.kind {
        case .error: "error"
        case .success: "success"
        case .info: "info"
        }
    }
}

extension View {
    /// Keeps the root's toasts above something this view pins to the bottom of the screen, `height`
    /// tall, for as long as the view is shown.
    func toastsStandAbove(_ height: Double, owner: String, toasts: ToastCenter) -> some View {
        onAppear { toasts.reserveBottom(height, for: owner) }
            .onChange(of: height) { _, next in toasts.reserveBottom(next, for: owner) }
            .onDisappear { toasts.reserveBottom(0, for: owner) }
    }
}
