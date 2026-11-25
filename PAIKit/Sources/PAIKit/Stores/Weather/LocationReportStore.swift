import Foundation
import Observation

public protocol LocationApiClient: Sendable {
    func postLocation(_ report: LocationReport) async throws
    func listMySignIns() async throws -> [SignIn]
}

extension PaiApiClient: LocationApiClient {}

/// Names the place at a coordinate, or `nil` when it cannot (no network, nothing there).
public typealias PlaceNameResolver = @Sendable (_ latitude: Double, _ longitude: Double) async -> String?

/// Which iPhone reports its location, and what a fix becomes on its way to the server.
///
/// The person's chosen phone is named by its sign-in in the user settings; this phone reports only
/// while that is its own current sign-in. The Apple-only half (permissions, the location manager)
/// hands every fix to ``report(_:)`` and asks ``usesThisDevice`` whether to keep listening.
@MainActor
@Observable
public final class LocationReportStore {
    /// A move shorter than this keeps the last place name instead of asking the geocoder again.
    static let placeReuseMeters = 500.0
    /// The same rounded spot reported again within this many seconds is one report, not two (a
    /// background wake and the foreground fix arrive together).
    static let duplicateWindow: TimeInterval = 30
    private static let signInCacheKey = "locationCurrentSignIn"

    /// This install's own sign-in, from the backend's list; kept so a background relaunch knows it
    /// before the network answers.
    public private(set) var currentSignInId: String?
    /// The last report the server accepted.
    public private(set) var lastReport: LocationReport?
    public private(set) var errorMessage: String?

    private let api: LocationApiClient
    private let settings: SettingsRegistryStore
    private let cache: SettingsKeyValueStore
    private let placeName: PlaceNameResolver
    private let now: @Sendable () -> Date
    private var lastDelivery: Date?
    private var lastPlaceSpot: (lat: Double, lon: Double)?
    private var isReporting = false
    private var queued: LocationFix?

    public init(
        api: LocationApiClient, settings: SettingsRegistryStore, cache: SettingsKeyValueStore,
        placeName: @escaping PlaceNameResolver, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.settings = settings
        self.cache = cache
        self.placeName = placeName
        self.now = now
        currentSignInId = cache.value(forKey: Self.signInCacheKey)
    }

    /// Whether this phone is the one that reports.
    public var usesThisDevice: Bool {
        guard let chosen = settings.locationSignInId else { return false }
        return chosen == currentSignInId
    }

    /// Reads which of the person's sign-ins is this install's own.
    public func resolveCurrentSignIn() async {
        guard let signIns = try? await api.listMySignIns() else { return }
        guard let own = signIns.first(where: { $0.current == true && $0.active }) else { return }
        currentSignInId = own.id
        cache.setValue(own.id, forKey: Self.signInCacheKey)
    }

    /// Makes this phone the reporting one, or stops it reporting. Turning it off leaves another
    /// phone's choice alone. Returns whether the setting now reads as asked.
    @discardableResult
    public func setUsesThisDevice(_ on: Bool) async -> Bool {
        errorMessage = nil
        if on {
            if currentSignInId == nil { await resolveCurrentSignIn() }
            guard let id = currentSignInId else {
                errorMessage = "Could not tell which sign-in this iPhone is"
                return false
            }
            return await settings.updatePerson(["location_sign_in_id": .string(id)])
        }
        guard usesThisDevice else { return true }
        return await settings.updatePerson(["location_sign_in_id": .null])
    }

    /// Sends one fix. Nothing leaves a phone that is not the chosen one. A fix that arrives while
    /// another is on its way waits for it, and only the newest of several waiting is sent.
    @discardableResult
    public func report(_ fix: LocationFix) async -> Bool {
        guard usesThisDevice, fix.accuracy >= 0 else { return false }
        if isReporting {
            queued = fix
            return false
        }
        isReporting = true
        defer { isReporting = false }
        var delivered = await send(fix)
        while let next = queued {
            queued = nil
            delivered = await send(next)
        }
        return delivered
    }

    private func send(_ fix: LocationFix) async -> Bool {
        let lat = Self.rounded(fix.latitude)
        let lon = Self.rounded(fix.longitude)
        if let last = lastReport, last.lat == lat, last.lon == lon, let delivered = lastDelivery,
            now().timeIntervalSince(delivered) < Self.duplicateWindow
        {
            return false
        }
        let place = await place(lat: lat, lon: lon)
        let report = LocationReport(
            lat: lat, lon: lon, accuracyM: Int(fix.accuracy.rounded()), place: place,
            recordedAt: AlarmTime.wireString(fix.timestamp))
        do {
            try await api.postLocation(report)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not send the location"
            return false
        }
        errorMessage = nil
        lastReport = report
        lastDelivery = now()
        return true
    }

    /// The previous place name while the phone is still near where it was resolved, else a fresh
    /// lookup, else none: an old city is never claimed for a new spot.
    private func place(lat: Double, lon: Double) async -> String? {
        if let spot = lastPlaceSpot, let last = lastReport?.place,
            GeoDistance.meters(spot.lat, spot.lon, lat, lon) < Self.placeReuseMeters
        {
            return last
        }
        let name = await placeName(lat, lon)
        if name != nil { lastPlaceSpot = (lat, lon) }
        return name
    }

    /// Three decimals is about a hundred metres, as much as the answer needs.
    static func rounded(_ degrees: Double) -> Double {
        (degrees * 1000).rounded() / 1000
    }
}

/// Great-circle distance between two coordinates.
enum GeoDistance {
    static func meters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6_371_000.0
        let toRadians = Double.pi / 180
        let dLat = (lat2 - lat1) * toRadians
        let dLon = (lon2 - lon1) * toRadians
        let a =
            sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * toRadians) * cos(lat2 * toRadians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
