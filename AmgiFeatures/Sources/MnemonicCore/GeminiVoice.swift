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
            /// An `ErrorInfo` (with a reason) or a `QuotaFailure` (with
            /// violations), among the details Google gives.
            struct Info: Decodable {
                struct Violation: Decodable {
                    let quotaId: String?
                    let quotaMetric: String?
                    /// The limit itself, such as 100 a day.
                    let quotaValue: Count?
                    /// Which model it's for, among others.
                    let quotaDimensions: [String: String]?
                }

                let reason: String?
                let violations: [Violation]?
            }

            let message: String
            let status: String?
            let details: [Info]?
        }

        let error: Detail
    }

    /// A number Google sends as a string ("100") or as a number.
    private struct Count: Decodable {
        let value: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = Int(text)
            } else {
                value = nil
            }
        }
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
        if error.status == "RESOURCE_EXHAUSTED" || statusCode == 429 {
            // Which limit ran out, a minute's or a day's, the free tier's
            // or a paid key's, and how big it is, is in the quota's details.
            let violations = (error.details ?? []).flatMap { $0.violations ?? [] }
            let names = violations.flatMap { [$0.quotaId, $0.quotaMetric].compactMap { $0 } } + [error.message]
            func mentions(_ word: String) -> Bool {
                names.contains {
                    $0.lowercased()
                        .replacingOccurrences(of: "_", with: "")
                        .replacingOccurrences(of: "-", with: "")
                        .contains(word)
                }
            }
            let daily = mentions("perday") || mentions("daily")
            let limit = violations.compactMap { $0.quotaValue?.value }.first
            let model = violations.compactMap { $0.quotaDimensions?["model"] }.first
            let advice = limitAdvice(daily: daily, freeTier: mentions("freetier"), limit: limit, model: model)
            // The day's limit on recordings, for Settings; not the rewrites'.
            let recordingsLimit = daily && model.map { $0.contains("tts") } != false ? limit : nil
            return .limited("\(advice) Google says: “\(error.message)”", daily: daily, limit: recordingsLimit)
        }
        let reasons = Set((error.details ?? []).compactMap(\.reason))
        guard let advice = advice(reasons: reasons, status: error.status ?? "", message: error.message, statusCode: statusCode) else {
            return .service(error.message)
        }
        return .service("\(advice) Google says: “\(error.message)”")
    }

    /// What a limit means, in words: the free tier's few recordings a day,
    /// a paid key's hundred or so, or a minute's worth.
    static func limitAdvice(daily: Bool, freeTier: Bool, limit: Int?, model: String?) -> String {
        let things = model.map { $0.contains("tts") } == false ? "card rewrites" : "recordings"
        let count = limit.map { "\($0) " } ?? ""
        switch (daily, freeTier) {
        case (true, true):
            return "This key is on Google’s free tier, which allows only \(count.isEmpty ? "a few " : count)\(things) a day, and today’s are used up. Turning on billing for the key in Google AI Studio raises the limit (to about 100 recordings a day). It starts again tomorrow; until then the iPhone voice reads."
        case (true, false):
            return "This key has made all the \(count)\(things) Google allows it today\(limit == nil ? " (about 100 on most accounts)" : ""). It starts again tomorrow; until then the iPhone voice reads."
        case (false, _):
            return "Google asked for a pause\(limit.map { ": this key may make \($0) \(things) a minute" } ?? ""). The iPhone voice reads for a minute."
        }
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
        try makeRequest(text: text, style: style, voice: voice, apiKey: apiKey, limit: maxInput, timeout: 90)
    }

    /// Several lines in one recording, to be cut apart (`RecordingSplitter`):
    /// the same voice and style, with a long pause after each line to cut
    /// at, longer than any pause inside a line, so it can't be mistaken.
    public static let togetherStyle = style + ", with a pause of about two seconds after each paragraph"

    /// The most text read in one recording of several lines: twenty cards'
    /// worth (`AIVoiceTogether.maxCharacters`) and to spare.
    static let maxTogetherInput = 6_000

    /// Each line a paragraph of its own. Five minutes of speech can take
    /// Gemini a few minutes to make, all of it before any answer comes.
    static func makeRequest(lines: [String], voice: String, apiKey: String) throws -> URLRequest {
        let text = lines.map(paragraph).joined(separator: "\n\n")
        return try makeRequest(
            text: text,
            style: togetherStyle,
            voice: voice,
            apiKey: apiKey,
            limit: maxTogetherInput,
            timeout: 360
        )
    }

    /// A line on one line, ending as a sentence does, so it's read as one
    /// and the pause after it falls where it's cut.
    static func paragraph(_ line: String) -> String {
        let flat = line
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = flat.last, !".?!…".contains(last) else { return flat }
        return flat + "."
    }

    private static func makeRequest(
        text: String,
        style: String,
        voice: String,
        apiKey: String,
        limit: Int,
        timeout: TimeInterval
    ) throws -> URLRequest {
        let line = GeminiAPI.Part(text: String(text.prefix(limit)), speechMetadata: .init(style: style))
        let body = Request(
            contents: [GeminiAPI.Content(role: "user", parts: [line])],
            generationConfig: .init(
                responseModalities: ["AUDIO"],
                speechConfig: .init(voiceConfig: .init(prebuiltVoiceConfig: .init(voiceName: voice)))
            )
        )
        return GeminiAPI.makeRequest(model: model, body: try JSONEncoder().encode(body), apiKey: apiKey, timeout: timeout)
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

// MARK: - Several lines in one recording

/// Several lines read in one recording, then cut apart into a recording
/// each. Google counts the Gemini voice's daily limit in requests, however
/// long each one's speech, so a few cards read together go much further.
///
/// Each cut is made in the pause between two lines, found from where the
/// phone's own speech recognition heard each line's words (`HeardWord`).
/// Every piece is then checked: its words must match its line, more
/// closely than the lines on either side, and its length must suit them.
/// A piece that fails is left out, to be recorded on its own.
public enum RecordingSplitter {
    /// A word the phone's speech recognition heard, and when, in seconds.
    public struct HeardWord: Equatable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// One channel of 16-bit sound.
    public struct Sound: Equatable, Sendable {
        public var samples: [Int16]
        public let sampleRate: Int

        public init(samples: [Int16], sampleRate: Int) {
            self.samples = samples
            self.sampleRate = sampleRate
        }

        /// A WAV file's sound, when it's 16-bit PCM in one channel, as
        /// Gemini's is; nil for anything else.
        public init?(wav: Data) {
            let bytes = [UInt8](wav)
            guard bytes.count >= 12,
                  Array(bytes[0..<4]) == Array("RIFF".utf8),
                  Array(bytes[8..<12]) == Array("WAVE".utf8)
            else { return nil }
            // Little-endian, as WAV has it.
            func number(at index: Int, length: Int) -> Int {
                (0..<length).reduce(0) { total, byte in total | Int(bytes[index + byte]) << (8 * byte) }
            }
            var rate: Int?
            var sound: [Int16]?
            var offset = 12
            while offset + 8 <= bytes.count {
                let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
                let size = number(at: offset + 4, length: 4)
                let body = offset + 8
                let end = min(body + size, bytes.count)
                if id == "fmt " {
                    guard end - body >= 16,
                          [1, 0xFFFE].contains(number(at: body, length: 2)),
                          number(at: body + 2, length: 2) == 1,
                          number(at: body + 14, length: 2) == 16
                    else { return nil }
                    rate = number(at: body + 4, length: 4)
                } else if id == "data" {
                    var values: [Int16] = []
                    values.reserveCapacity((end - body) / 2)
                    var index = body
                    while index + 1 < end {
                        values.append(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
                        index += 2
                    }
                    sound = values
                }
                // Chunks take an even number of bytes.
                offset = body + size + size % 2
            }
            guard let rate, rate > 0, let sound else { return nil }
            self.init(samples: sound, sampleRate: rate)
        }

        public var duration: Double {
            Double(samples.count) / Double(sampleRate)
        }

        /// The sound from `start` to `end`, in seconds.
        public func clip(from start: Double, to end: Double) -> Sound {
            let rate = Double(sampleRate)
            let first = min(max(Int(start * rate), 0), samples.count)
            let last = min(max(Int(end * rate), first), samples.count)
            return Sound(samples: Array(samples[first..<last]), sampleRate: sampleRate)
        }

        /// As a WAV file.
        public var wav: Data {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(samples.count * 2)
            for sample in samples {
                let bits = UInt16(bitPattern: sample)
                bytes.append(UInt8(truncatingIfNeeded: bits))
                bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
            return GeminiSpeech.wavFile(pcm: Data(bytes), sampleRate: sampleRate)
        }
    }

    /// A line's own recording, or why it couldn't be cut out cleanly.
    public enum Piece: Equatable, Sendable {
        case cut(Sound)
        case failed(String)

        public var sound: Sound? {
            if case .cut(let sound) = self { return sound }
            return nil
        }

        public var problem: String? {
            if case .failed(let problem) = self { return problem }
            return nil
        }
    }

    /// A stretch of a recording, in seconds.
    public struct Phrase: Equatable, Sendable {
        public let start: Double
        public let end: Double
    }

    /// The recording in stretches of speech, split at its longer pauses,
    /// for speech recognition to hear one at a time (`HeardWord`s' times
    /// then offset by each one's start). Given a long recording whole, it
    /// can lose what came before a long pause, and with it most of the
    /// lines.
    public static func phrases(in sound: Sound) -> [Phrase] {
        let frame = Double(frameSize(sound)) / Double(sound.sampleRate)
        let levels = loudness(of: sound)
        guard let loudest = levels.max(), loudest > 0 else { return [] }
        let quiet = max(loudest * 0.03, 40)
        // The pauses between stretches of speech, not those at either end.
        let breaks = gaps(in: levels, below: quiet, frame: frame)
            .filter { $0.length >= phraseBreak && $0.start > frame / 2 && $0.end < sound.duration - frame / 2 }
            .map(\.middle)
        let bounds = [0] + breaks + [sound.duration]
        return zip(bounds, bounds.dropFirst()).map { Phrase(start: $0, end: $1) }
    }

    /// The shortest pause a recording is split into phrases at.
    static let phraseBreak = 0.45

    /// Each of `lines`, read one after another in `sound`, cut out of it.
    public static func split(_ sound: Sound, lines: [String], heard: [HeardWord]) -> [Piece] {
        guard !lines.isEmpty else { return [] }
        let frame = Double(frameSize(sound)) / Double(sound.sampleRate)
        let levels = loudness(of: sound)
        guard let loudest = levels.max(), loudest > 0 else {
            return lines.map { _ in .failed("The recording is silent.") }
        }
        // Gemini's pauses are close to digital silence; the quietest
        // sounds in a word are far above this.
        let quiet = max(loudest * 0.03, 40)
        let pauses = gaps(in: levels, below: quiet, frame: frame)

        let lineWords = lines.map(words)
        var expected: [(word: String, line: Int)] = []
        for (line, list) in lineWords.enumerated() {
            for word in list {
                expected.append((word: word, line: line))
            }
        }
        let tokens = heard.flatMap { word in
            words(word.text).map { HeardWord(text: $0, start: word.start, end: word.end) }
        }
        let owners = align(tokens.map(\.text), to: expected.map(\.word))

        // When each line's words were heard.
        var firstHeard = [Double?](repeating: nil, count: lines.count)
        var lastHeard = [Double?](repeating: nil, count: lines.count)
        for (token, owner) in zip(tokens, owners) {
            guard let owner else { continue }
            let line = expected[owner].line
            firstHeard[line] = min(firstHeard[line] ?? token.start, token.start)
            lastHeard[line] = max(lastHeard[line] ?? token.end, token.end)
        }

        // Each cut, in the longest pause between one line's last word and
        // the next line's first, and why not, where there's none.
        var cuts = [Double?](repeating: nil, count: lines.count - 1)
        var whyNot = [String?](repeating: nil, count: lines.count - 1)
        for boundary in cuts.indices {
            guard let end = lastHeard[boundary], let start = firstHeard[boundary + 1] else {
                whyNot[boundary] = "A line next to it wasn’t heard, so where it starts or ends couldn’t be told."
                continue
            }
            guard end <= start + slack else {
                whyNot[boundary] = "Its words and the next line’s seemed to overlap."
                continue
            }
            let between = pauses.filter { $0.middle >= end - slack && $0.middle <= start + slack && $0.length >= minimumPause }
            cuts[boundary] = between.max { $0.length < $1.length }?.middle
            if cuts[boundary] == nil {
                whyNot[boundary] = "There was no pause between it and the line next to it."
            }
        }
        // Out of order, they can't both be right.
        for boundary in cuts.indices.dropLast() {
            if let cut = cuts[boundary], let next = cuts[boundary + 1], next <= cut {
                cuts[boundary] = nil
                cuts[boundary + 1] = nil
                whyNot[boundary] = "Its words were heard out of order."
                whyNot[boundary + 1] = "Its words were heard out of order."
            }
        }

        return lines.indices.map { (index: Int) -> Piece in
            guard firstHeard[index] != nil else {
                return .failed("None of its words were heard.")
            }
            let from = index == 0 ? 0 : cuts[index - 1]
            let to = index == lines.count - 1 ? sound.duration : cuts[index]
            guard let from, let to, from < to else {
                let before = index > 0 ? whyNot[index - 1] : nil
                let after = index < lines.count - 1 ? whyNot[index] : nil
                return .failed(before ?? after ?? "The pause before or after it couldn’t be found.")
            }
            let said = tokens
                .filter { (($0.start + $0.end) / 2) >= from && (($0.start + $0.end) / 2) < to }
                .map(\.text)
                .joined()
            let wanted = lineWords[index].joined()
            let match = similarity(said, wanted)
            guard match >= minimumMatch else {
                return .failed("Its words didn’t match the line (\(Int((match * 100).rounded()))% alike).")
            }
            // Something said twice, or more than the line, can still be
            // half alike.
            if wanted.count >= 4 {
                let length = Double(said.count) / Double(wanted.count)
                guard length >= 0.6, length <= 1.5 else {
                    return .failed("It has \(length > 1 ? "more" : "fewer") words than the line.")
                }
            }
            for neighbour in [index - 1, index + 1] where lines.indices.contains(neighbour) {
                if similarity(said, lineWords[neighbour].joined()) > match {
                    return .failed("It sounded more like the line next to it.")
                }
            }
            guard let piece = trimmed(sound, from: from, to: to, loudness: levels, quiet: quiet, frame: frame) else {
                return .failed("There’s no speech in it.")
            }
            if wanted.count >= 20 {
                let pace = Double(wanted.count) / piece.duration
                guard pace >= 3, pace <= 40 else {
                    return .failed("It’s too long or too short for its words.")
                }
            }
            return .cut(piece)
        }
    }

    /// How far a word's timing may be off.
    static let slack = 0.25
    /// The shortest pause a cut is made in.
    static let minimumPause = 0.15
    /// How alike a piece's words and its line's must be, letter for letter:
    /// enough for a drug name heard as a few words, not for another line.
    static let minimumMatch = 0.5

    // MARK: Words

    /// A text's words as compared: lower case, letters and digits only.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// 1 for the same letters, down to 0 for nothing alike: the share of
    /// the longer that needn't change to make the other.
    static func similarity(_ first: String, _ second: String) -> Double {
        let a = first.unicodeScalars.map(\.value)
        let b = second.unicodeScalars.map(\.value)
        let longer = max(a.count, b.count)
        guard longer > 0 else { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let replace = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(replace, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(longer)
    }

    /// For each word heard, the expected word it was taken for, if any:
    /// the cheapest way to turn one list into the other, where a word
    /// heard a little wrong ("etho" for "ethosuximide") costs less than
    /// one heard quite wrong.
    static func align(_ heard: [String], to expected: [String]) -> [Int?] {
        let rows = heard.count
        let columns = expected.count
        guard rows > 0, columns > 0 else { return [Int?](repeating: nil, count: rows) }
        let width = columns + 1
        var cost = [Double](repeating: 0, count: (rows + 1) * width)
        // 0: paired, 1: a word heard but not in the lines, 2: a word of the
        // lines not heard.
        var step = [UInt8](repeating: 0, count: (rows + 1) * width)
        for row in 1...rows {
            cost[row * width] = Double(row)
            step[row * width] = 1
        }
        for column in 1...columns {
            cost[column] = Double(column)
            step[column] = 2
        }
        for row in 1...rows {
            for column in 1...columns {
                let paired = cost[(row - 1) * width + column - 1] + pairingCost(heard[row - 1], expected[column - 1])
                let extra = cost[(row - 1) * width + column] + 1
                let missed = cost[row * width + column - 1] + 1
                let cell = row * width + column
                if paired <= extra && paired <= missed {
                    cost[cell] = paired
                    step[cell] = 0
                } else if extra <= missed {
                    cost[cell] = extra
                    step[cell] = 1
                } else {
                    cost[cell] = missed
                    step[cell] = 2
                }
            }
        }
        var owners = [Int?](repeating: nil, count: rows)
        var row = rows
        var column = columns
        while row > 0, column > 0 {
            switch step[row * width + column] {
            case 0:
                owners[row - 1] = column - 1
                row -= 1
                column -= 1
            case 1:
                row -= 1
            default:
                column -= 1
            }
        }
        return owners
    }

    private static func pairingCost(_ heard: String, _ expected: String) -> Double {
        if heard == expected { return 0 }
        let alike = similarity(heard, expected)
        if alike >= 0.8 { return 0.3 }
        if alike >= 0.5 { return 0.7 }
        return 1
    }

    // MARK: Sound

    /// A pause: a stretch below the quiet level, in seconds.
    struct Gap: Equatable {
        let start: Double
        let end: Double

        var length: Double { end - start }
        var middle: Double { (start + end) / 2 }
    }

    /// Hundredths of a second.
    static func frameSize(_ sound: Sound) -> Int {
        max(sound.sampleRate / 100, 1)
    }

    /// How loud each frame is: its root mean square.
    static func loudness(of sound: Sound) -> [Double] {
        let size = frameSize(sound)
        var frames: [Double] = []
        frames.reserveCapacity(sound.samples.count / size + 1)
        var index = 0
        while index < sound.samples.count {
            let end = min(index + size, sound.samples.count)
            var sum = 0.0
            for sample in sound.samples[index..<end] {
                let value = Double(sample)
                sum += value * value
            }
            frames.append((sum / Double(end - index)).squareRoot())
            index = end
        }
        return frames
    }

    static func gaps(in loudness: [Double], below quiet: Double, frame: Double) -> [Gap] {
        var found: [Gap] = []
        var start: Int?
        for (index, level) in loudness.enumerated() {
            if level < quiet {
                if start == nil { start = index }
            } else if let began = start {
                found.append(Gap(start: Double(began) * frame, end: Double(index) * frame))
                start = nil
            }
        }
        if let began = start {
            found.append(Gap(start: Double(began) * frame, end: Double(loudness.count) * frame))
        }
        return found
    }

    /// The speech between `from` and `to`, with a moment's quiet kept
    /// either side as a recording of its own has, and the very ends faded
    /// in and out so they can't click.
    static func trimmed(
        _ sound: Sound,
        from: Double,
        to: Double,
        loudness: [Double],
        quiet: Double,
        frame: Double
    ) -> Sound? {
        let firstFrame = max(Int(from / frame), 0)
        let lastFrame = min(Int((to / frame).rounded(.up)), loudness.count)
        guard firstFrame < lastFrame,
              let speechStart = (firstFrame..<lastFrame).first(where: { loudness[$0] >= quiet }),
              let speechEnd = (firstFrame..<lastFrame).last(where: { loudness[$0] >= quiet })
        else { return nil }
        let begin = max(from, Double(speechStart) * frame - 0.15)
        let finish = min(to, Double(speechEnd + 1) * frame + 0.25)
        let rate = Double(sound.sampleRate)
        let first = min(max(Int(begin * rate), 0), sound.samples.count)
        let last = min(max(Int(finish * rate), first), sound.samples.count)
        var samples = Array(sound.samples[first..<last])
        let fade = min(sound.sampleRate / 200, samples.count / 2)
        for index in 0..<fade {
            let gain = Double(index) / Double(fade)
            samples[index] = Int16(Double(samples[index]) * gain)
            let end = samples.count - 1 - index
            samples[end] = Int16(Double(samples[end]) * gain)
        }
        return Sound(samples: samples, sampleRate: sound.sampleRate)
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
    /// Google's limit for the key is reached, for the day or the minute;
    /// `limit` is the day's, when Google says.
    case limited(String, daily: Bool, limit: Int?)
    case unimplemented

    public var errorDescription: String? {
        switch self {
        case .noKey:
            "Add your Gemini key first: Settings → Review → AI Voice."
        case .service(let message), .limited(let message, _, _):
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
    /// Several lines read one after another in one recording, as a WAV
    /// file, to be cut apart (`RecordingSplitter`).
    public var recordTogether: @Sendable (_ lines: [String], _ voice: String) async throws -> Data
    /// Whether there's a Gemini key to use.
    public var hasKey: @Sendable () -> Bool

    public init(
        script: @escaping @Sendable (_ card: CardScript.Card) async throws -> CardScript.Lines,
        record: @escaping @Sendable (_ text: String, _ voice: String) async throws -> Data,
        recordTogether: @escaping @Sendable (_ lines: [String], _ voice: String) async throws -> Data = { _, _ in
            throw CardVoiceError.unimplemented
        },
        hasKey: @escaping @Sendable () -> Bool
    ) {
        self.script = script
        self.record = record
        self.recordTogether = recordTogether
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
        recordTogether: { lines, voice in
            guard let apiKey = GeminiAPIKey.load() else { throw CardVoiceError.noKey }
            let request = try GeminiSpeech.makeRequest(lines: lines, voice: voice, apiKey: apiKey)
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
