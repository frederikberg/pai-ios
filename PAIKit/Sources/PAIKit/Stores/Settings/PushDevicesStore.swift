import Foundation
import Observation

/// What `PushDevicesStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol PushDevicesApiClient: Sendable {
    func listPushDevices() async throws -> [PushDevice]
    func patchPushDevice(id: String, _ patch: PushDevicePatch) async throws
}

extension PaiApiClient: PushDevicesApiClient {}

/// A pause the person can pick: how long, as the moment it ends.
public struct PushPausePreset: Equatable, Sendable, Identifiable {
    public let label: String
    public let until: Date
    public var id: String { label }

    /// The four choices every client offers: 30 min, 1 h, 3 h, and until the next 07:00 in the
    /// zone the person is in.
    public static func presets(now: Date, zone: TimeZone) -> [PushPausePreset] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let morning = calendar.nextDate(
            after: now, matching: DateComponents(hour: 7, minute: 0, second: 0), matchingPolicy: .nextTime)
        var presets = [
            PushPausePreset(label: "30 min", until: now.addingTimeInterval(30 * 60)),
            PushPausePreset(label: "1 h", until: now.addingTimeInterval(3600)),
            PushPausePreset(label: "3 h", until: now.addingTimeInterval(3 * 3600)),
        ]
        if let morning { presets.append(PushPausePreset(label: "Until 07:00", until: morning)) }
        return presets
    }
}

/// The caller's own devices (iPhones and browsers) with what each chose: on or off, paused until
/// a time, and an iPhone's sleep window. The phone changes only its own row's on/off and pause;
/// the sleep window it writes itself at registration.
@MainActor
@Observable
public final class PushDevicesStore {
    /// `nil` until the first read succeeds.
    public private(set) var devices: [PushDevice]?
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false

    private let api: any PushDevicesApiClient

    public init(api: any PushDevicesApiClient) {
        self.api = api
    }

    /// This phone's own row, once the list has been read.
    public var thisDevice: PushDevice? { devices?.first { $0.thisDevice && $0.kind == .iphone } }

    /// The person's other devices: every browser and any other iPhone.
    public var otherDevices: [PushDevice] { (devices ?? []).filter { $0.id != thisDevice?.id } }

    public func load() async {
        do {
            devices = try await api.listPushDevices()
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the devices"
        }
    }

    public func setEnabled(_ enabled: Bool, on device: PushDevice) async {
        await change(device, PushDevicePatch(pushEnabled: enabled))
    }

    public func pause(_ device: PushDevice, until: Date) async {
        await change(device, PushDevicePatch(pause: .until(IsoTimestamp.utcString(from: until))))
    }

    public func resume(_ device: PushDevice) async {
        await change(device, PushDevicePatch(pause: .resume))
    }

    private func change(_ device: PushDevice, _ patch: PushDevicePatch) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.patchPushDevice(id: device.id, patch)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not change the device"
            return
        }
        await load()
    }
}

/// What the notification switches add up to.
public enum NotificationMatrix {
    /// Whether no push can reach any of the person's devices: every push switch they have is off.
    /// The inbox keeps everything regardless, which is what the page says beside it.
    public static func reachesNoDevice(person: [String: SettingValue]) -> Bool {
        let switches = ["push_agent_messages", "push_alerts", "push_reminders"].compactMap { person[$0]?.boolValue }
        return !switches.isEmpty && switches.allSatisfy { !$0 }
    }
}
