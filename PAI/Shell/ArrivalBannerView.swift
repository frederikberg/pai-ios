import PAIKit
import SwiftUI

/// The small banner a notification arriving while the app is open shows at the top, for a moment:
/// the app's own stand-in for the push it did not get. A tap opens Notifications; Back returns to
/// where it was.
struct ArrivalBannerView: View {
    let store: ArrivalBannerStore
    let onOpen: () -> Void

    var body: some View {
        VStack {
            if let banner = store.current {
                Button {
                    store.dismiss()
                    onOpen()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(PaiPalette.primary400)
                        Text(banner.title)
                            .font(PaiTypography.captionEmphasized.font)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New notification: \(banner.title)")
                .accessibilityIdentifier("arrival-banner")
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(banner.id)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.2), value: store.current)
        .allowsHitTesting(store.current != nil)
    }
}
