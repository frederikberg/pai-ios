import PAIKit

/// The one way a shortcut opens the new-session screen with a type already chosen: the quick-actions
/// tiles and the MailVerdict assistant entry both go through here.
@MainActor
enum NewSessionLaunch {
    /// Records the launch choice where `CreateSessionView` already looks for one, arms hands-free
    /// dictation or the camera if the caller asks for it, and replaces the path.
    ///
    /// The draft is written locally and pushed to the server without being waited on. A local
    /// write is what the screen about to appear actually reads, and holding the navigation for a
    /// round trip would make a button pressed without looking feel like it did nothing.
    static func start(
        type: String, call: Bool = false, camera: Bool = false, environment: AppEnvironment, drafts: DraftStore
    ) {
        // While the sessions are put away nothing is armed and nothing is drafted: the router
        // would refuse the screen, and a call armed for a screen that never opens would start at
        // the next opening of the new-session sheet.
        guard !environment.router.isAsleep else {
            environment.router.popToRoot()
            return
        }
        // `selectWorkingDir(nil)` first: a directory chosen on a previous visit is what makes a
        // session custom, and it outranks the type, so leaving one in place would launch the
        // wrong thing while the screen showed the right pill.
        drafts.selectWorkingDir(nil)
        drafts.selectSessionType(type)
        if call {
            CallModeLaunchRequest.shared.arm()
        } else {
            CallModeLaunchRequest.shared.cancel()
        }
        if camera {
            CameraLaunchRequest.shared.arm()
        } else {
            CameraLaunchRequest.shared.cancel()
        }
        environment.router.replace(with: [.createSession])
    }
}
