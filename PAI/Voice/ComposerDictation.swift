import PAIKit

/// How one composer relates to the app's single microphone: whether the running take is its own,
/// whether its button may start one, and what a tap does to a take running elsewhere. The recorder
/// is app-wide and exclusive, so every composer that dictates asks the same questions about its own
/// draft key; they are answered here once.
@MainActor
struct ComposerDictation {
    let controller: VoiceRecorderController
    /// The draft the take writes into: a session's id, or a device-only key such as the diary's.
    let draftKey: String

    /// Whether the running take is this composer's — a take started on another draft must not turn
    /// this composer into a recording one.
    var isRecordingHere: Bool {
        controller.activeDraftKey == draftKey && controller.state != .idle
    }

    /// A live take rewrites the text continuously, so the field has no caret to offer while one runs.
    var ownsBox: Bool { isRecordingHere && controller.activeSttMode == .live }

    /// Recording, finishing or owed: what keeps a composer's dictation controls on screen.
    var ownsTake: Bool {
        isRecordingHere || controller.isTranscribingBatch(draftKey: draftKey)
            || controller.hasStuckBatchTake(draftKey: draftKey)
    }

    /// Words of this composer's own take that have not arrived yet: a composer that cannot send
    /// without them waits. A stuck take is not waited on, since it may never finish.
    var wordsAreOnTheWay: Bool {
        isRecordingHere || controller.isTranscribingBatch(draftKey: draftKey)
    }

    /// Whether the mic button here is a live control: nothing is recording, or the take is this one.
    var micIsMine: Bool { controller.state == .idle || isRecordingHere }

    private var handoverAction: VoiceHandoverAction {
        let running = controller.state == .idle ? nil : controller.activeDraftKey
        return VoiceHandover.forMicrophoneTap(sessionID: draftKey, microphoneTakeSessionID: running)
    }

    /// `nil` defers to the button's own gate (`controller.canStart`). `true` forces it tappable
    /// even though that gate refuses: a tap that takes over a take running elsewhere does not
    /// start anything until that take has stopped.
    var canStartOverride: Bool? {
        guard !isRecordingHere else { return nil }
        switch handoverAction {
        case .startOnly, .alreadyHere: return nil
        case .stopMicrophoneTake: return true
        }
    }

    /// The start/stop tap. A tap during Finishing stops waiting (`stop()`'s own wait is already
    /// running by then); any other take of this composer ends through the ordinary stop; a take
    /// running elsewhere is stopped first, so its words are written before this one begins.
    func toggle(sttMode: VoiceSttMode, preText: String) async {
        if isRecordingHere {
            if controller.state == .stopping {
                controller.stopWaiting()
                return
            }
            await controller.stop()
            return
        }
        switch handoverAction {
        case .stopMicrophoneTake: await controller.stop()
        case .startOnly, .alreadyHere: break
        }
        await controller.start(draftKey: draftKey, preText: preText, sttMode: sttMode)
    }
}
