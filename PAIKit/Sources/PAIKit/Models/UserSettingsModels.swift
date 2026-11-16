import Foundation

/// One person's own settings (`GET/PUT /api/settings/me`), the same on every device they sign in
/// from. Mirrors `UserSettings` in the web's `types.ts`.
public struct UserSettings: Codable, Sendable, Equatable {
    /// What a plain press on the microphone starts; the long press and the plus menu start the other.
    public var recordingMode: VoiceSttMode
    /// An ElevenLabs voice id replies are read aloud in; `nil` is the server's default voice.
    public var playbackVoiceId: String?
    public var playbackSpeed: Double
    /// Whether an agent's notification to this person may also go out by e-mail.
    public var emailNotifications: Bool
    /// Seconds between the pushes of a ringing alarm (the server allows 2 to 60).
    public var alarmRingIntervalS: Int
    /// Seconds an alarm keeps ringing when nobody dismisses it (the server allows 10 to 600).
    public var alarmRingDurationS: Int
    /// The sign-in of the one iPhone that reports its location in the background; `nil` when no
    /// phone does.
    public var locationSignInId: String?

    public init(
        recordingMode: VoiceSttMode = .live, playbackVoiceId: String? = nil, playbackSpeed: Double = 1,
        emailNotifications: Bool = true, alarmRingIntervalS: Int = 5, alarmRingDurationS: Int = 60,
        locationSignInId: String? = nil
    ) {
        self.recordingMode = recordingMode
        self.playbackVoiceId = playbackVoiceId
        self.playbackSpeed = playbackSpeed
        self.emailNotifications = emailNotifications
        self.alarmRingIntervalS = alarmRingIntervalS
        self.alarmRingDurationS = alarmRingDurationS
        self.locationSignInId = locationSignInId
    }

    enum CodingKeys: String, CodingKey {
        case recordingMode = "recording_mode"
        case playbackVoiceId = "playback_voice_id"
        case playbackSpeed = "playback_speed"
        case emailNotifications = "email_notifications"
        case alarmRingIntervalS = "alarm_ring_interval_s"
        case alarmRingDurationS = "alarm_ring_duration_s"
        case locationSignInId = "location_sign_in_id"
    }
}

/// The slots `PUT /api/settings/me` takes, any subset. Only the voice and the location sign-in
/// can be cleared, which is spelled out as `null`; a slot left `nil` here is not sent at all.
public struct UserSettingsPatch: Encodable, Sendable, Equatable {
    /// A slot that can be left alone, set, or cleared to `null`.
    public enum Slot<Value: Sendable & Equatable>: Sendable, Equatable {
        case unchanged
        case set(Value)
        case clear
    }

    public typealias Voice = Slot<String>

    public var recordingMode: VoiceSttMode?
    public var playbackVoice: Voice = .unchanged
    public var playbackSpeed: Double?
    public var emailNotifications: Bool?
    public var alarmRingIntervalS: Int?
    public var alarmRingDurationS: Int?
    public var locationSignIn: Slot<String> = .unchanged

    public init(
        recordingMode: VoiceSttMode? = nil, playbackVoice: Voice = .unchanged, playbackSpeed: Double? = nil,
        emailNotifications: Bool? = nil, alarmRingIntervalS: Int? = nil, alarmRingDurationS: Int? = nil,
        locationSignIn: Slot<String> = .unchanged
    ) {
        self.recordingMode = recordingMode
        self.playbackVoice = playbackVoice
        self.playbackSpeed = playbackSpeed
        self.emailNotifications = emailNotifications
        self.alarmRingIntervalS = alarmRingIntervalS
        self.alarmRingDurationS = alarmRingDurationS
        self.locationSignIn = locationSignIn
    }

    enum CodingKeys: String, CodingKey {
        case recordingMode = "recording_mode"
        case playbackVoiceId = "playback_voice_id"
        case playbackSpeed = "playback_speed"
        case emailNotifications = "email_notifications"
        case alarmRingIntervalS = "alarm_ring_interval_s"
        case alarmRingDurationS = "alarm_ring_duration_s"
        case locationSignInId = "location_sign_in_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(recordingMode, forKey: .recordingMode)
        switch playbackVoice {
        case .unchanged: break
        case let .set(id): try container.encode(id, forKey: .playbackVoiceId)
        case .clear: try container.encodeNil(forKey: .playbackVoiceId)
        }
        try container.encodeIfPresent(playbackSpeed, forKey: .playbackSpeed)
        try container.encodeIfPresent(emailNotifications, forKey: .emailNotifications)
        try container.encodeIfPresent(alarmRingIntervalS, forKey: .alarmRingIntervalS)
        try container.encodeIfPresent(alarmRingDurationS, forKey: .alarmRingDurationS)
        switch locationSignIn {
        case .unchanged: break
        case let .set(id): try container.encode(id, forKey: .locationSignInId)
        case .clear: try container.encodeNil(forKey: .locationSignInId)
        }
    }

    /// The settings as they stand once the patch is applied, for showing a change before the
    /// server has answered.
    public func applied(to settings: UserSettings) -> UserSettings {
        var next = settings
        if let recordingMode { next.recordingMode = recordingMode }
        switch playbackVoice {
        case .unchanged: break
        case let .set(id): next.playbackVoiceId = id
        case .clear: next.playbackVoiceId = nil
        }
        if let playbackSpeed { next.playbackSpeed = playbackSpeed }
        if let emailNotifications { next.emailNotifications = emailNotifications }
        if let alarmRingIntervalS { next.alarmRingIntervalS = alarmRingIntervalS }
        if let alarmRingDurationS { next.alarmRingDurationS = alarmRingDurationS }
        switch locationSignIn {
        case .unchanged: break
        case let .set(id): next.locationSignInId = id
        case .clear: next.locationSignInId = nil
        }
        return next
    }
}
