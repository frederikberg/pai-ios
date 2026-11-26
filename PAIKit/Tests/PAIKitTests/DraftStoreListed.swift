@testable import PAIKit

/// A store that has already answered its first draft listing, the state every running app reaches
/// within moments of launch. Tests of something other than that first listing start here, since a
/// store that has not listed holds every write back.
@MainActor
func listedDraftStore(
    api: some DraftsFetching, clock: WallClock = SystemWallClock(),
    scheduler: DraftScheduler = RealDraftScheduler(),
    diagnosticsLog: VoiceDiagnosticsLog? = nil,
    localPersistence: SettingsKeyValueStore? = nil
) -> DraftStore {
    let store = DraftStore(
        api: api, clock: clock, scheduler: scheduler, diagnosticsLog: diagnosticsLog,
        localPersistence: localPersistence)
    store.hasListed = true
    return store
}
