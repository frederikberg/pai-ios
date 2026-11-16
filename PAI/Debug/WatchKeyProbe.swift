import PAIKit

#if DEBUG

    /// What `-PaiFixtureWatchKeys` does once the watch-key rows are on screen: the same calls the
    /// row's own buttons make, so the presentations they trigger are the real ones. Runs once per
    /// launch, whichever view asks first.
    @MainActor
    enum WatchKeyProbe {
        private static var ran = false

        /// `askRevoke` is what the Revoke swipe button does; it must make the confirmation appear.
        static func run(store: WatchKeysStore, askRevoke: (WatchKey) -> Void) async {
            guard PaiFixtureLaunch.isEnabled(), let mode = PaiFixtureLaunch.requestedWatchKeyProbe(), !ran else {
                return
            }
            ran = true
            // Lets the settings screen finish drawing and the first list read land.
            try? await Task.sleep(for: .seconds(2))
            switch mode {
            case "create":
                await store.create(name: "Probe watch")
            case "revoke-ask":
                if let key = store.keys.first { askRevoke(key) }
            case "revoke":
                if let key = store.keys.first {
                    askRevoke(key)
                    try? await Task.sleep(for: .seconds(2))
                    await store.revoke(key)
                }
            default:
                break
            }
            FixtureFacts.shared.record("watchKeyProbe", "\(mode):done")
        }
    }

#endif
