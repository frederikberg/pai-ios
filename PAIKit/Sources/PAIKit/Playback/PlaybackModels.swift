import Foundation

/// One cut of a reply, synthesised on demand. `durationMs` is exact once `ready`, else `nil` and
/// `estMs` is the estimate.
public struct PlaybackSegment: Codable, Sendable, Equatable {
    public let index: Int
    public let chars: Int
    public let estMs: Int
    public let durationMs: Int?
    public let ready: Bool

    enum CodingKeys: String, CodingKey {
        case index, chars, ready
        case estMs = "est_ms"
        case durationMs = "duration_ms"
    }

    public init(index: Int, chars: Int, estMs: Int, durationMs: Int? = nil, ready: Bool = false) {
        self.index = index
        self.chars = chars
        self.estMs = estMs
        self.durationMs = durationMs
        self.ready = ready
    }
}

/// This person's ElevenLabs credits today against their daily ceiling (`nil` until the month has
/// been read once). Keys beyond these are ignored.
public struct PlaybackUsage: Codable, Sendable, Equatable {
    public let creditsUsed: Int
    public let dailyCreditCap: Int?
    public let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case creditsUsed = "credits_used"
        case dailyCreditCap = "daily_credit_cap"
        case resetsAt = "resets_at"
    }
}

/// `GET /api/session/{id}/playback/{message_id}`: free, synthesises nothing.
public struct PlaybackManifest: Codable, Sendable, Equatable {
    public let messageId: Int
    public let voiceId: String?
    public let model: String
    public let segments: [PlaybackSegment]
    public let usage: PlaybackUsage

    enum CodingKeys: String, CodingKey {
        case model, segments, usage
        case messageId = "message_id"
        case voiceId = "voice_id"
    }
}

/// A playback route refused. Its `detail` is an object (`code`, `message`) rather than the string
/// every other route answers, so `PaiError` would have shown it as a decoding failure; `message`
/// is the sentence to show the person as it is.
public struct PlaybackRefusal: Error, Sendable, Equatable {
    public let status: Int
    /// `playback_cap_reached`, `playback_saving_credits`, ... Absent on a plain 404 or a proxy answer.
    public let code: String?
    public let message: String

    public init(status: Int, code: String?, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// 404 means the reply has nothing to read aloud.
    public var isNothingToRead: Bool { status == 404 }

    /// Refusals about one part alone (its voice failed on that text): the player skips the part and
    /// plays on. Every other refusal is a limit that would refuse the next part too, so it stops.
    public static let partFailureCodes: Set<String> = ["playback_synthesis_failed"]

    public var isPartFailure: Bool { code.map(Self.partFailureCodes.contains) ?? false }

    /// What a part that failed earlier answers with when it is asked for again.
    static let unreadablePart = PlaybackRefusal(
        status: 502, code: "playback_synthesis_failed", message: "This part could not be read aloud.")

    /// Reads a refusal from an error response's body.
    public static func parse(status: Int, body: Data) -> PlaybackRefusal {
        struct Body: Decodable {
            struct Detail: Decodable {
                let code: String?
                let message: String?
            }
            enum Shape {
                case object(Detail)
                case text(String)
            }
            let shape: Shape?

            enum CodingKeys: String, CodingKey { case detail }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let detail = try? container.decode(Detail.self, forKey: .detail) {
                    shape = .object(detail)
                } else if let text = try? container.decode(String.self, forKey: .detail) {
                    shape = .text(text)
                } else {
                    shape = nil
                }
            }
        }
        switch (try? JSONDecoder().decode(Body.self, from: body))?.shape {
        case let .object(detail)?:
            return PlaybackRefusal(
                status: status, code: detail.code, message: detail.message ?? "HTTP \(status)")
        case let .text(text)?:
            return PlaybackRefusal(status: status, code: nil, message: text)
        case nil:
            return PlaybackRefusal(status: status, code: nil, message: "HTTP \(status)")
        }
    }
}

/// One voice of the ElevenLabs account, as `GET /api/playback/voices` lists it.
public struct PlaybackVoiceChoice: Codable, Sendable, Equatable, Identifiable {
    public let voiceId: String
    public let name: String
    /// ISO 639-1, when the voice says.
    public let language: String?
    public let gender: String?

    public var id: String { voiceId }

    /// What the picker shows: the name, with the language when there is one.
    public var label: String { language.map { "\(name) (\($0))" } ?? name }

    enum CodingKeys: String, CodingKey {
        case name, language, gender
        case voiceId = "voice_id"
    }

    public init(voiceId: String, name: String, language: String? = nil, gender: String? = nil) {
        self.voiceId = voiceId
        self.name = name
        self.language = language
        self.gender = gender
    }
}

/// `GET /api/playback/voices`: what a person can pick from.
public struct PlaybackVoices: Codable, Sendable, Equatable {
    /// The account's voices; empty while ElevenLabs cannot be read.
    public let elevenlabs: [PlaybackVoiceChoice]
    /// The voice of everyone who has not picked their own.
    public let defaultVoiceId: String
    public let builtinVoiceId: String

    enum CodingKeys: String, CodingKey {
        case elevenlabs
        case defaultVoiceId = "default_voice_id"
        case builtinVoiceId = "builtin_voice_id"
    }

    public init(elevenlabs: [PlaybackVoiceChoice], defaultVoiceId: String, builtinVoiceId: String) {
        self.elevenlabs = elevenlabs
        self.defaultVoiceId = defaultVoiceId
        self.builtinVoiceId = builtinVoiceId
    }

    /// What the default voice is called: its name from the list, else its id.
    public var defaultVoiceLabel: String {
        elevenlabs.first { $0.voiceId == defaultVoiceId }?.label ?? defaultVoiceId
    }
}
