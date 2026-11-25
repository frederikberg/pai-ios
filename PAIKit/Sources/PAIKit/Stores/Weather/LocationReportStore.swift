import Foundation
import Observation

public protocol LocationApiClient: Sendable {
    func postLocationPoints(_ points: [LocationPoint]) async throws -> LocationPointsAnswer
    func getPlacesMonitor() async throws -> PlacesMonitorAnswer
    func listMySignIns() async throws -> [SignIn]
}

extension PaiApiClient: LocationApiClient {}

/// Names the place at a coordinate, or `nil` when it cannot (no network, nothing there).
public typealias PlaceNameResolver = @Sendable (_ latitude: Double, _ longitude: Double) async -> String?

/// Which iPhone reports its location, and what a fix, a visit or a geofence crossing becomes on
/// its way to the server.
///
/// The person's chosen phone is named by its sign-in in the user settings; this phone reports only
/// while that is its own current sign-in. The Apple-only half (permissions, the location manager,
/// the region monitor) hands everything to this store and asks ``usesThisDevice`` whether to keep
/// listening. Every point goes through the on-disk ``LocationQueue`` first and is flushed in
/// batches, so a lost connection or a background relaunch never loses one.
///
/// The owner's phone also geofences the places the server names (`GET /api/places/monitor`): the
/// store holds that list and the version it came with, and tells the Apple half when it changes.
@MainActor
@Observable
public final class LocationReportStore {
    /// A move shorter than this keeps the last place name instead of asking the geocoder again.
    static let placeReuseMeters = 500.0
    private static let signInCacheKey = "locationCurrentSignIn"
    private static let placesCacheKey = "locationMonitoredPlaces"
    private static let placesVersionCacheKey = "locationMonitoredPlacesVersion"
    private static let ownerCacheKey = "locationOwnerDevice"

    /// This install's own sign-in, from the backend's list; kept so a background relaunch knows it
    /// before the network answers.
    public private(set) var currentSignInId: String?
    public private(set) var errorMessage: String?
    /// The places this phone geofences, as of the last read; kept across launches so a region event
    /// that relaunches the app can be placed before the network answers.
    public private(set) var monitoredPlaces: [MonitoredPlace]

    /// Called with the full list and whether its version changed whenever the places to geofence
    /// are read. The Apple half applies the difference.
    public var onPlacesChange: (@MainActor (_ places: [MonitoredPlace], _ versionChanged: Bool) -> Void)?

    private let api: LocationApiClient
    private let settings: SettingsRegistryStore
    private let cache: SettingsKeyValueStore
    private let queue: LocationQueue
    private let placeName: PlaceNameResolver
    private let capabilities: @MainActor () -> Capabilities
    private var placesVersion: String?
    /// Whether the person this phone is signed in as is the owner, as last read from `/api/me` and
    /// kept across launches: a region event that relaunches the app arrives before `/api/me` answers.
    private var isOwnerDevice: Bool
    private var lastPlaceSpot: (lat: Double, lon: Double)?
    private var lastPlaceName: String?
    private var isFlushing = false
    private var flushAgain = false

    public init(
        api: LocationApiClient, settings: SettingsRegistryStore, cache: SettingsKeyValueStore, queue: LocationQueue,
        placeName: @escaping PlaceNameResolver, capabilities: @escaping @MainActor () -> Capabilities
    ) {
        self.api = api
        self.settings = settings
        self.cache = cache
        self.queue = queue
        self.placeName = placeName
        self.capabilities = capabilities
        currentSignInId = cache.value(forKey: Self.signInCacheKey)
        monitoredPlaces = cache.value(forKey: Self.placesCacheKey) ?? []
        placesVersion = cache.value(forKey: Self.placesVersionCacheKey)
        isOwnerDevice = cache.value(forKey: Self.ownerCacheKey) ?? false
    }

    /// Whether this phone is the one that reports.
    public var usesThisDevice: Bool {
        guard let chosen = settings.locationSignInId else { return false }
        return chosen == currentSignInId
    }

    /// Whether this phone geofences the owner's places and records visits: only the owner has a
    /// history and places; a guest's phone sends its latest position and nothing else.
    public var keepsHistory: Bool { usesThisDevice && isOwnerDevice }

    /// Takes the role from `/api/me` once it has answered; until then the last known one stands.
    public func syncRole() {
        let known = capabilities()
        guard known.isKnown else { return }
        isOwnerDevice = known.canReadLocationHistory
        cache.setValue(isOwnerDevice, forKey: Self.ownerCacheKey)
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

    // MARK: Recording

    /// Queues one fix and sends what is waiting. Nothing leaves a phone that is not the chosen one.
    /// Returns whether the queue is empty afterwards, that is, the fix reached the server.
    @discardableResult
    public func report(_ fix: LocationFix) async -> Bool {
        guard usesThisDevice, fix.accuracy >= 0 else { return false }
        let locality = await place(lat: fix.latitude, lon: fix.longitude)
        guard let point = LocationPointMapping.point(for: fix, locality: locality) else { return false }
        await queue.append(point)
        await flush()
        return await queue.count == 0
    }

    /// Queues a visit's arrival and departure, whichever it has.
    public func recordVisit(_ visit: VisitSample) async {
        guard keepsHistory else { return }
        let locality = await place(lat: visit.latitude, lon: visit.longitude)
        for point in LocationPointMapping.points(for: visit, locality: locality) {
            await queue.append(point)
        }
        await flush()
    }

    /// Queues the crossing of a geofence. A place this phone does not know cannot be placed on a
    /// map, so its event is dropped.
    public func recordRegion(placeId: String, entered: Bool, at date: Date) async {
        guard keepsHistory, let place = monitoredPlaces.first(where: { $0.id == placeId }) else { return }
        await queue.append(LocationPointMapping.point(for: place, entered: entered, at: date))
        await flush()
    }

    /// Sends the queue, oldest first, in batches the server accepts. A batch the server cannot
    /// take (a transport failure, a refusal that may pass) stays queued for the next flush; one it
    /// rejects outright would never be accepted and is dropped so it cannot block the points behind it.
    public func flush() async {
        guard usesThisDevice else { return }
        if isFlushing {
            flushAgain = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            flushAgain = false
            await sendBatches()
        } while flushAgain
    }

    private func sendBatches() async {
        while true {
            let batch = await queue.batch()
            if batch.isEmpty { return }
            do {
                let answer = try await api.postLocationPoints(batch)
                await queue.remove(first: batch.count)
                errorMessage = nil
                if keepsHistory, let version = answer.placesVersion, version != placesVersion {
                    await refreshPlaces()
                }
            } catch let error as PaiError where error.isPermanentRejection {
                await queue.remove(first: batch.count)
                errorMessage = error.userMessage
            } catch {
                return
            }
        }
    }

    // MARK: Places

    /// Reads the places to geofence and tells the Apple half when they changed. Only the owner's
    /// chosen phone does it.
    public func refreshPlaces() async {
        guard keepsHistory else { return }
        guard let answer = try? await api.getPlacesMonitor() else { return }
        let changed = answer.placesVersion != placesVersion || answer.places != monitoredPlaces
        placesVersion = answer.placesVersion
        monitoredPlaces = answer.places
        cache.setValue(answer.places, forKey: Self.placesCacheKey)
        cache.setValue(answer.placesVersion, forKey: Self.placesVersionCacheKey)
        onPlacesChange?(answer.places, changed)
    }

    // MARK: Place names

    /// The previous place name while the phone is still near where it was resolved, else a fresh
    /// lookup, else none: an old city is never claimed for a new spot.
    private func place(lat: Double, lon: Double) async -> String? {
        if let spot = lastPlaceSpot, let last = lastPlaceName,
            GeoDistance.meters(spot.lat, spot.lon, lat, lon) < Self.placeReuseMeters
        {
            return last
        }
        let name = await placeName(lat, lon)
        if name != nil {
            lastPlaceSpot = (lat, lon)
            lastPlaceName = name
        }
        return name
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
