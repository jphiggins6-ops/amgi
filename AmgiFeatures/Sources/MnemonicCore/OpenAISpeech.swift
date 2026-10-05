//
//  OpenAISpeech.swift
//  MnemonicCore
//

public import Foundation
public import Dependencies

/// Card text read aloud by OpenAI's speech model, for hands-free mode's AI
/// voice: one call per text, which comes back as MP3 audio. Uses the key
/// the pictures and the Graveyard use (`MnemonicAPIKey`). Building the
/// request and reading the response are pure, so both are tested without
/// a key.
public enum OpenAISpeech {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!

    /// About $0.015 a minute of speech (October 2026).
    public static let model = "gpt-4o-mini-tts"

    /// How the voice should sound. When this changes, bump `style`.
    static let instructions = """
        You are reading a flashcard aloud to a medical student who is studying hands-free. \
        Sound like a calm, friendly tutor: warm, clear and natural, at an unhurried, \
        conversational pace. Say medical terms, drug names and abbreviations the way a \
        doctor would. Pause briefly at each full stop. Where the text says "blank", say \
        "blank" plainly: it stands for the word the student has to recall.
        """

    /// Part of each recording's name (`CardVoiceRecordings`), so recordings
    /// made with older instructions aren't mistaken for new ones.
    public static let style = "1"

    /// The most text the model reads in one go.
    static let maxInput = 4_096

    struct RequestBody: Codable, Equatable {
        let model: String
        let input: String
        let voice: String
        let instructions: String
        let responseFormat: String

        enum CodingKeys: String, CodingKey {
            case model, input, voice, instructions
            case responseFormat = "response_format"
        }
    }

    static func makeRequest(text: String, voice: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            input: String(text.prefix(maxInput)),
            voice: voice,
            instructions: instructions,
            responseFormat: "mp3"
        ))
        return request
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    /// The audio, or an error carrying OpenAI's own explanation.
    static func audio(from body: Data, statusCode: Int) throws -> Data {
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error.message
            throw CardExplanationError.service(message ?? "OpenAI answered with HTTP \(statusCode).")
        }
        guard !body.isEmpty else {
            throw CardExplanationError.service("OpenAI sent back no audio.")
        }
        return body
    }
}

// MARK: - Dependency

/// Records text read aloud in one of OpenAI's voices ("marin"), as MP3.
public struct CardVoiceClient: Sendable {
    public var record: @Sendable (_ text: String, _ voice: String) async throws -> Data
    /// Whether there's a key to record with.
    public var hasKey: @Sendable () -> Bool

    public init(
        record: @escaping @Sendable (_ text: String, _ voice: String) async throws -> Data,
        hasKey: @escaping @Sendable () -> Bool
    ) {
        self.record = record
        self.hasKey = hasKey
    }
}

extension CardVoiceClient: DependencyKey {
    public static let liveValue = CardVoiceClient(
        record: { text, voice in
            guard let apiKey = MnemonicAPIKey.load() else { throw CardExplanationError.noKey }
            let request = try OpenAISpeech.makeRequest(text: text, voice: voice, apiKey: apiKey)
            let (body, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try OpenAISpeech.audio(from: body, statusCode: statusCode)
        },
        hasKey: { MnemonicAPIKey.load() != nil }
    )

    public static let testValue = CardVoiceClient(
        record: { _, _ in throw CardExplanationError.unimplemented },
        hasKey: { false }
    )
}

extension DependencyValues {
    public var cardVoice: CardVoiceClient {
        get { self[CardVoiceClient.self] }
        set { self[CardVoiceClient.self] = newValue }
    }
}
