//
//  GeminiVoice.swift
//  MnemonicCore
//

public import Foundation
public import Dependencies

/// Hands-free mode's AI voice, from Google Gemini, in two steps: a card's
/// sides rewritten the way a tutor would say them (`CardScript`), then read
/// aloud (`GeminiSpeech`). Both use the Gemini key (`GeminiAPIKey`).
/// Building each request and reading each response are pure, so they're
/// tested without a key.
enum GeminiAPI {
    static func endpoint(model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    static func makeRequest(model: String, body: Data, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint(model: model), timeoutInterval: timeout)
        request.httpMethod = "POST"
        // In a header rather than the URL, where it could end up in a log.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    struct Content: Codable, Equatable {
        var role: String?
        var parts: [Part]
    }

    struct Part: Codable, Equatable {
        var text: String?
        var speechMetadata: SpeechMetadata?
        var inlineData: InlineData?
        var thought: Bool?
    }

    struct SpeechMetadata: Codable, Equatable {
        var style: String
    }

    struct InlineData: Codable, Equatable {
        var mimeType: String
        var data: String
    }

    private struct Response: Decodable {
        struct Candidate: Decodable {
            /// No parts at all when the answer was cut short.
            struct Answer: Decodable {
                let parts: [Part]?
            }

            let content: Answer?
            let finishReason: String?
        }

        struct Feedback: Decodable {
            let blockReason: String?
        }

        let candidates: [Candidate]?
        let promptFeedback: Feedback?
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            struct Info: Decodable {
                let reason: String?
            }

            let message: String
            let status: String?
            let details: [Info]?
        }

        let error: Detail
    }

    /// The parts of Gemini's answer, or an error carrying its own
    /// explanation.
    static func parts(from body: Data, statusCode: Int) throws -> [Part] {
        guard (200..<300).contains(statusCode) else {
            throw failure(from: body, statusCode: statusCode)
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: body) else {
            throw CardVoiceError.service("Gemini sent back an answer this app can't read.")
        }
        if let blocked = response.promptFeedback?.blockReason {
            throw CardVoiceError.service("Gemini turned this card down (\(blocked)).")
        }
        guard let parts = response.candidates?.first?.content?.parts, !parts.isEmpty else {
            let reason = response.candidates?.first?.finishReason.map { " (\($0))" } ?? ""
            throw CardVoiceError.service("Gemini sent back nothing\(reason).")
        }
        return parts
    }

    /// Google's refusal in its own words, after what to do about it when
    /// it's one people run into.
    static func failure(from body: Data, statusCode: Int) -> CardVoiceError {
        guard let error = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error else {
            return .service("Gemini answered with HTTP \(statusCode).")
        }
        let reasons = Set((error.details ?? []).compactMap(\.reason))
        guard let advice = advice(reasons: reasons, status: error.status ?? "", message: error.message, statusCode: statusCode) else {
            return .service(error.message)
        }
        return .service("\(advice) Google says: “\(error.message)”")
    }

    /// What to do about the refusals people run into, from the reason
    /// Google gives (`ErrorInfo.reason`), or its status or words.
    static func advice(reasons: Set<String>, status: String, message: String, statusCode: Int) -> String? {
        let words = message.lowercased()
        if reasons.contains("API_KEY_SERVICE_BLOCKED") || words.hasPrefix("requests to this api") {
            return "Google won’t let this key use Gemini. Keys that start with “AIza” stopped working for Gemini in September 2026, as did keys limited to other Google services. Make a new key at aistudio.google.com/apikey (new ones start with “AQ.”) and paste it in Settings → Review → AI Voice."
        }
        if reasons.contains("API_KEY_INVALID") || words.contains("api key not valid") || status == "UNAUTHENTICATED" {
            return "Google doesn’t recognize this key. Copy it again from aistudio.google.com/apikey and paste it in Settings → Review → AI Voice."
        }
        if reasons.contains("SERVICE_DISABLED") || words.contains("has not been used in project") {
            return "The Gemini API is switched off in this key’s Google Cloud project. A new key made in Google AI Studio comes with it switched on."
        }
        if status == "RESOURCE_EXHAUSTED" || statusCode == 429 {
            return "This key has used up what Gemini allows for now. Turning on billing in Google AI Studio lifts the free tier’s limit of a few recordings a day."
        }
        if reasons.contains("BILLING_DISABLED") || words.contains("billing") {
            return "Billing isn’t set up for this key’s project: turn it on in Google AI Studio."
        }
        if words.contains("location is not supported") {
            return "Gemini isn’t available from where you are."
        }
        return nil
    }
}

// MARK: - Reading aloud

/// A line of text read aloud by Gemini's speech model.
public enum GeminiSpeech {
    /// Gemini 3.8 Flash TTS: $9 a million audio tokens, at 25 tokens a
    /// second, so about 1.4¢ a minute through 2026 and twice that from
    /// January 2027.
    public static let model = "gemini-3.8-flash-tts"

    /// How every line is said. One short style that never changes, as
    /// Google advises, keeps the voice the same from card to card.
    public static let style = "warm, clear and unhurried, like a friendly tutor"

    /// The text is read word for word, so it's kept to a length no card
    /// side needs.
    static let maxInput = 4_000

    struct Request: Codable, Equatable {
        struct GenerationConfig: Codable, Equatable {
            struct SpeechConfig: Codable, Equatable {
                struct VoiceConfig: Codable, Equatable {
                    struct Prebuilt: Codable, Equatable {
                        let voiceName: String
                    }

                    let prebuiltVoiceConfig: Prebuilt
                }

                let voiceConfig: VoiceConfig
            }

            let responseModalities: [String]
            let speechConfig: SpeechConfig
        }

        let contents: [GeminiAPI.Content]
        let generationConfig: GenerationConfig
    }

    static func makeRequest(text: String, voice: String, apiKey: String) throws -> URLRequest {
        let line = GeminiAPI.Part(text: String(text.prefix(maxInput)), speechMetadata: .init(style: style))
        let body = Request(
            contents: [GeminiAPI.Content(role: "user", parts: [line])],
            generationConfig: .init(
                responseModalities: ["AUDIO"],
                speechConfig: .init(voiceConfig: .init(prebuiltVoiceConfig: .init(voiceName: voice)))
            )
        )
        return GeminiAPI.makeRequest(model: model, body: try JSONEncoder().encode(body), apiKey: apiKey, timeout: 90)
    }

    /// The audio as a WAV file. Gemini sends either a whole one or bare
    /// 16-bit PCM ("audio/L16;codec=pcm;rate=24000"), which gets a header.
    static func wav(from body: Data, statusCode: Int) throws -> Data {
        let parts = try GeminiAPI.parts(from: body, statusCode: statusCode)
        guard let inline = parts.compactMap(\.inlineData).first,
              let audio = Data(base64Encoded: inline.data),
              !audio.isEmpty
        else { throw CardVoiceError.service("Gemini sent back no audio.") }
        if audio.starts(with: Data("RIFF".utf8)) { return audio }
        return wavFile(pcm: audio, sampleRate: sampleRate(of: inline.mimeType))
    }

    /// 24000 for "audio/L16;codec=pcm;rate=24000", and when none is given.
    static func sampleRate(of mimeType: String) -> Int {
        for parameter in mimeType.split(separator: ";") {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            if pair.count == 2,
               pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "rate",
               let rate = Int(pair[1].trimmingCharacters(in: .whitespaces)) {
                return rate
            }
        }
        return 24_000
    }

    /// Mono 16-bit PCM behind a 44-byte WAV header.
    static func wavFile(pcm: Data, sampleRate: Int) -> Data {
        var file = Data()
        func text(_ string: String) {
            file.append(contentsOf: Array(string.utf8))
        }
        // Little-endian, as WAV has it.
        func uint32(_ value: Int) {
            let bits = UInt32(truncatingIfNeeded: value)
            file.append(contentsOf: [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) })
        }
        func uint16(_ value: Int) {
            let bits = UInt16(truncatingIfNeeded: value)
            file.append(contentsOf: [0, 8].map { UInt8(truncatingIfNeeded: bits >> $0) })
        }
        text("RIFF")
        uint32(36 + pcm.count)
        text("WAVE")
        text("fmt ")
        uint32(16)
        uint16(1)  // PCM
        uint16(1)  // mono
        uint32(sampleRate)
        uint32(sampleRate * 2)  // bytes a second
        uint16(2)  // bytes a frame
        uint16(16)  // bits a sample
        text("data")
        uint32(pcm.count)
        file.append(pcm)
        return file
    }
}

// MARK: - Said the way a tutor says it

/// The step before the voice: a card's sides as written, rewritten the way
/// a tutor would say them, so a cloze is asked as a question ("What's the
/// drug of choice for absence seizures?"), shorthand comes out in words,
/// and lists and tables read as speech.
public enum CardScript {
    /// Gemini 3.1 Flash-Lite: a few hundredths of a cent a card.
    public static let model = "gemini-3.1-flash-lite"

    /// Part of each script's name (`CardVoiceRecordings`), so scripts
    /// written to older instructions aren't reused. Bump it whenever
    /// `instructions` change.
    public static let version = "1"

    /// A card's sides as written: a blank shows as "[...]", or as its hint
    /// in brackets.
    public struct Card: Equatable, Sendable {
        public let question: String
        public let answer: String
        public let deckName: String

        public init(question: String, answer: String, deckName: String) {
            self.question = question
            self.answer = answer
            self.deckName = deckName
        }
    }

    /// What's said for each side.
    public struct Lines: Codable, Equatable, Sendable {
        public let question: String
        public let answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    static let instructions = """
        You prepare flashcards to be read aloud to a medical student who is studying \
        hands-free: they hear the card but can't see it. You're given a card's question \
        side and answer side, as written. Reply with two things.

        "question": what a friendly tutor would say to ask this card, so it's clear by ear alone.
        - A blank written [...] is what the student has to recall. Turn the sentence into a \
        natural spoken question about it: "[...] is the drug of choice for absence seizures" \
        becomes "What's the drug of choice for absence seizures?" A blank with words in it, \
        like [drug], is a hint: use it ("Which drug is…").
        - With several blanks, ask for each of them.
        - Never say, hint at or give away the answer, even though you can see it.

        "answer": the answer as a short, natural reply, such as "Ethosuximide." For a blank, \
        just what fills it, said as a phrase; don't repeat the question.

        For both:
        - Say symbols, abbreviations, units and numbers the way a doctor says them aloud: \
        ↑ is "increased", → is "leads to", "5 mg/kg" is "5 milligrams per kilogram", \
        "BP 120/80" is "blood pressure 120 over 80". Keep acronyms that are said as letters, \
        like ECG or MRI.
        - Keep every fact, name and number exactly as on the card, and add nothing: no \
        explanations, mnemonics or encouragement.
        - Turn lists and tables into flowing speech. Leave out what can't be heard, such as \
        pictures, source references and tags.
        - Plain spoken text only, with no markdown, bullet points or emoji.
        """

    static func prompt(for card: Card) -> String {
        """
        Deck: \(card.deckName)

        Question side, as written:
        \(card.question)

        Answer side, as written:
        \(card.answer)
        """
    }

    struct Schema: Codable, Equatable {
        let type: String
        var properties: [String: Schema]?
        var required: [String]?
    }

    struct Request: Codable, Equatable {
        struct GenerationConfig: Codable, Equatable {
            let responseMimeType: String
            let responseSchema: Schema
        }

        let systemInstruction: GeminiAPI.Content
        let contents: [GeminiAPI.Content]
        let generationConfig: GenerationConfig
    }

    static func makeRequest(card: Card, apiKey: String) throws -> URLRequest {
        let text = Schema(type: "STRING")
        let body = Request(
            systemInstruction: GeminiAPI.Content(parts: [GeminiAPI.Part(text: instructions)]),
            contents: [GeminiAPI.Content(role: "user", parts: [GeminiAPI.Part(text: prompt(for: card))])],
            generationConfig: .init(
                responseMimeType: "application/json",
                responseSchema: Schema(
                    type: "OBJECT",
                    properties: ["question": text, "answer": text],
                    required: ["question", "answer"]
                )
            )
        )
        return GeminiAPI.makeRequest(model: model, body: try JSONEncoder().encode(body), apiKey: apiKey, timeout: 60)
    }

    /// The script Gemini wrote, trimmed.
    static func lines(from body: Data, statusCode: Int) throws -> Lines {
        let parts = try GeminiAPI.parts(from: body, statusCode: statusCode)
        var json = parts.filter { $0.thought != true }.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Should a fence come back around the JSON anyway.
        if json.hasPrefix("```") {
            json = json
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
        }
        guard let lines = try? JSONDecoder().decode(Lines.self, from: Data(json.utf8)) else {
            throw CardVoiceError.service("Gemini's script for this card couldn't be read.")
        }
        return Lines(
            question: lines.question.trimmingCharacters(in: .whitespacesAndNewlines),
            answer: lines.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Whether the spoken question gives the answer away: a short answer
    /// turns up in it, though not in the question as written.
    public static func givesAwayAnswer(_ lines: Lines, card: Card) -> Bool {
        let answer = card.answer
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard answer.count >= 3, answer.count <= 40 else { return false }
        return lines.question.lowercased().contains(answer) && !card.question.lowercased().contains(answer)
    }
}

// MARK: - Errors

public enum CardVoiceError: LocalizedError, Equatable {
    case noKey
    case service(String)
    case unimplemented

    public var errorDescription: String? {
        switch self {
        case .noKey:
            "Add your Gemini key first: Settings → Review → AI Voice."
        case .service(let message):
            "Gemini: \(message)"
        case .unimplemented:
            "The AI voice isn't available here."
        }
    }
}

// MARK: - Dependency

/// The AI voice's two calls to Gemini.
public struct CardVoiceClient: Sendable {
    /// A card's sides as a tutor would say them.
    public var script: @Sendable (_ card: CardScript.Card) async throws -> CardScript.Lines
    /// Text read aloud in one of Gemini's voices ("Kore"), as a WAV file.
    public var record: @Sendable (_ text: String, _ voice: String) async throws -> Data
    /// Whether there's a Gemini key to use.
    public var hasKey: @Sendable () -> Bool

    public init(
        script: @escaping @Sendable (_ card: CardScript.Card) async throws -> CardScript.Lines,
        record: @escaping @Sendable (_ text: String, _ voice: String) async throws -> Data,
        hasKey: @escaping @Sendable () -> Bool
    ) {
        self.script = script
        self.record = record
        self.hasKey = hasKey
    }
}

extension CardVoiceClient: DependencyKey {
    public static let liveValue = CardVoiceClient(
        script: { card in
            guard let apiKey = GeminiAPIKey.load() else { throw CardVoiceError.noKey }
            let request = try CardScript.makeRequest(card: card, apiKey: apiKey)
            let (body, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try CardScript.lines(from: body, statusCode: statusCode)
        },
        record: { text, voice in
            guard let apiKey = GeminiAPIKey.load() else { throw CardVoiceError.noKey }
            let request = try GeminiSpeech.makeRequest(text: text, voice: voice, apiKey: apiKey)
            let (body, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try GeminiSpeech.wav(from: body, statusCode: statusCode)
        },
        hasKey: { GeminiAPIKey.load() != nil }
    )

    public static let testValue = CardVoiceClient(
        script: { _ in throw CardVoiceError.unimplemented },
        record: { _, _ in throw CardVoiceError.unimplemented },
        hasKey: { false }
    )
}

extension DependencyValues {
    public var cardVoice: CardVoiceClient {
        get { self[CardVoiceClient.self] }
        set { self[CardVoiceClient.self] = newValue }
    }
}
