import PAIKit
import SwiftUI
import UIKit

/// Which iPhone tells the server where the person is, for the Weather app and, for the owner, the
/// location history and reminders at places. A person's own setting, so a guest has it too.
struct LocationSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts

    private var reporter: LocationReporter { LocationReporter.shared }

    var body: some View {
        if let store = environment.connection?.location {
            Section {
                Toggle(
                    "Use this iPhone for location",
                    isOn: Binding(
                        get: { store.usesThisDevice },
                        set: { on in
                            Task {
                                await store.setUsesThisDevice(on)
                                reporter.reconcile()
                            }
                        })
                )
                .accessibilityIdentifier("location-toggle")
                if store.usesThisDevice, let status = status(reporter.permission.access) {
                    Text(status.text)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    if ownerHistory {
                        Text("Monitored places: \(store.monitoredPlaces.count) of \(PlaceMonitorPlan.maxPlaces)")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                            .accessibilityIdentifier("location-monitored-places")
                    }
                    if status.offersSettings {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Location · \(SettingsScope.synced.label)")
            } footer: {
                Text(footer)
            }
            .id(FixtureScrollAnchor.location.rawValue)
            .onChange(of: store.errorMessage) { _, message in
                if let message { toasts.show(message, kind: .error) }
            }
        }
    }

    private var ownerHistory: Bool {
        environment.connection?.me.capabilities.canReadLocationHistory == true
    }

    private var footer: String {
        if ownerHistory {
            return
                "Keeps your location history on your PAI server for reminders at places and the weather. One iPhone reports it."
        }
        return
            "Only your latest location is kept on your PAI server, to answer whether it will rain where you are. One iPhone reports it; the others stay silent."
    }

    private func status(_ access: LocationPermission.Access) -> (text: String, offersSettings: Bool)? {
        switch access {
        case .undetermined: nil
        case .denied: ("Location access is off for PAI, so nothing can be reported.", true)
        case .whenInUse:
            (
                "Allowed while the app is open. Choose Always so your location is kept up to date in the background.",
                true
            )
        case .always: ("Always allowed: your location updates in the background.", false)
        }
    }
}
