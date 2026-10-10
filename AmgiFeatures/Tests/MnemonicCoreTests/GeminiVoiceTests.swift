//
//  GeminiVoiceTests.swift
//  MnemonicCoreTests
//

import Foundation
import Testing
@testable import MnemonicCore

@Suite struct GeminiVoiceTests {
    /// The request body, as JSON objects.
    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A response carrying `parts`, as Gemini sends one.
    private func response(parts: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["candidates": [["content": ["role": "model", "parts": parts]]]])
    }

    // MARK: - Reading aloud

    @Test func theSpeechRequestAsksForAudioInTheVoiceWithTheStyleKeptApart() throws {
        let request = try GeminiSpeech.makeRequest(text: "What's the drug of choice?", voice: "Kore", apiKey: "test-key")
        #expect(request.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash-tts:generateContent")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(request.url?.query == nil, "the key stays out of the URL")

        let json = try body(of: request)
        let contents = try #require(json["contents"] as? [[String: Any]])
        let part = try #require((contents.first?["parts"] as? [[String: Any]])?.first)
        #expect(part["text"] as? String == "What's the drug of choice?")
        #expect((part["speechMetadata"] as? [String: Any])?["style"] as? String == GeminiSpeech.style)
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseModalities"] as? [String] == ["AUDIO"])
        let voice = ((config["speechConfig"] as? [String: Any])?["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any]
        #expect(voice?["voiceName"] as? String == "Kore")
    }

    @Test func barePCMGetsAWAVHeader() throws {
        let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])
        let body = try response(parts: [["inlineData": ["mimeType": "audio/L16;codec=pcm;rate=16000", "data": pcm.base64EncodedString()]]])
        let wav = try GeminiSpeech.wav(from: body, statusCode: 200)
        #expect(wav.count == 44 + pcm.count)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav.subdata(in: 8..<16) == Data("WAVEfmt ".utf8))
        #expect(Array(wav.subdata(in: 24..<28)) == [0x80, 0x3E, 0, 0], "16000 a second, little-endian")
        #expect(Array(wav.subdata(in: 40..<44)) == [8, 0, 0, 0], "eight bytes of sound")
        #expect(wav.suffix(pcm.count) == pcm)
    }

    @Test func aWholeWAVComesBackAsItIs() throws {
        let file = GeminiSpeech.wavFile(pcm: Data([9, 9]), sampleRate: 24_000)
        let body = try response(parts: [["inlineData": ["mimeType": "audio/wav", "data": file.base64EncodedString()]]])
        #expect(try GeminiSpeech.wav(from: body, statusCode: 200) == file)
    }

    @Test func theSampleRateComesFromTheMIMEType() {
        #expect(GeminiSpeech.sampleRate(of: "audio/L16;codec=pcm;rate=24000") == 24_000)
        #expect(GeminiSpeech.sampleRate(of: "audio/L16; rate=16000") == 16_000)
        #expect(GeminiSpeech.sampleRate(of: "audio/wav") == 24_000, "the default")
    }

    @Test func googlesOwnErrorComesBack() throws {
        let other = Data(#"{"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}"#.utf8)
        #expect(throws: CardVoiceError.service("Internal error encountered.")) {
            try GeminiSpeech.wav(from: other, statusCode: 500)
        }
        #expect(throws: CardVoiceError.service("Gemini sent back no audio.")) {
            try GeminiSpeech.wav(from: try response(parts: [["text": "hello"]]), statusCode: 200)
        }
        let blocked = Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)
        #expect(throws: CardVoiceError.service("Gemini turned this card down (SAFETY).")) {
            try GeminiSpeech.wav(from: blocked, statusCode: 200)
        }
    }

    @Test func aRefusedKeySaysWhatToDo() {
        let blocked = Data(#"""
            {"error":{"code":403,"message":"Requests to this API generativelanguage.googleapis.com method google.ai.generativelanguage.v1beta.GenerativeService.GenerateContent are blocked.","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_SERVICE_BLOCKED","domain":"googleapis.com"}]}}
            """#.utf8)
        let message = GeminiAPI.failure(from: blocked, statusCode: 403).errorDescription ?? ""
        #expect(message.contains("aistudio.google.com/apikey"))
        #expect(message.contains("“AIza”"))
        #expect(message.hasSuffix("are blocked.”"), "Google's own words come last")

        let invalid = Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8)
        #expect(GeminiAPI.failure(from: invalid, statusCode: 400).errorDescription?.contains("doesn’t recognize this key") == true)
    }

    @Test func googlesLimitsAreToldApart() {
        let minute = Data(#"{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}"#.utf8)
        guard case .limited(_, let daily, _) = GeminiAPI.failure(from: minute, statusCode: 429) else {
            Issue.record("not a limit")
            return
        }
        #expect(!daily)

        let day = Data(#"""
            {"error":{"code":429,"message":"You exceeded your current quota.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_requests_per_model_per_day","quotaId":"GenerateRequestsPerDayPerProjectPerModel"}]}]}}
            """#.utf8)
        let error = GeminiAPI.failure(from: day, statusCode: 429)
        guard case .limited(let message, let daily, _) = error else {
            Issue.record("not a limit")
            return
        }
        #expect(daily)
        #expect(message.contains("tomorrow"))
        #expect(error.errorDescription?.hasPrefix("Gemini: ") == true)
    }

    @Test func theFreeTiersSmallDailyLimitIsNamed() {
        let freeTier = Data(#"""
            {"error":{"code":429,"message":"You exceeded your current quota.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier","quotaDimensions":{"location":"global","model":"gemini-3.8-flash-tts"},"quotaValue":"10"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"37s"}]}}
            """#.utf8)
        guard case .limited(let message, let daily, let limit) = GeminiAPI.failure(from: freeTier, statusCode: 429) else {
            Issue.record("not a limit")
            return
        }
        #expect(daily)
        #expect(limit == 10)
        #expect(message.contains("free tier"))
        #expect(message.contains("only 10 recordings a day"))
        #expect(message.contains("billing"))
    }

    @Test func aKeysKindShowsInHowItStarts() {
        #expect(GeminiAPIKey.kind(of: "AQ.Ab8RN6Lexample") == .auth)
        #expect(GeminiAPIKey.kind(of: "AIzaSyExample") == .standard)
        #expect(GeminiAPIKey.kind(of: "sk-proj-example") == .unknown)
    }

    // MARK: - The script

    @Test func theScriptRequestSendsTheCardAndAsksForJSON() throws {
        let card = CardScript.Card(question: "[...] is the drug of choice for absence seizures.", answer: "Ethosuximide", deckName: "Neuro")
        let request = try CardScript.makeRequest(card: card, apiKey: "test-key")
        #expect(request.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")

        let json = try body(of: request)
        let system = try #require(((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(system.contains("Never say, hint at or give away the answer"))
        let prompt = try #require(((json["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(prompt.contains("Deck: Neuro"))
        #expect(prompt.contains("[...] is the drug of choice for absence seizures."))
        #expect(prompt.contains("Ethosuximide"))
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        let schema = try #require(config["responseSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "OBJECT")
        #expect(schema["required"] as? [String] == ["question", "answer"])
    }

    @Test func theScriptIsReadFromTheReply() throws {
        let reply = try response(parts: [
            ["text": "Thinking it over…", "thought": true],
            ["text": #"{"question": " What's the drug of choice for absence seizures? ", "answer": "Ethosuximide."}"#],
        ])
        #expect(try CardScript.lines(from: reply, statusCode: 200)
            == CardScript.Lines(question: "What's the drug of choice for absence seizures?", answer: "Ethosuximide."))

        let fenced = try response(parts: [["text": "```json\n{\"question\":\"Q?\",\"answer\":\"A.\"}\n```"]])
        #expect(try CardScript.lines(from: fenced, statusCode: 200) == CardScript.Lines(question: "Q?", answer: "A."))

        #expect(throws: CardVoiceError.service("Gemini's script for this card couldn't be read.")) {
            try CardScript.lines(from: try response(parts: [["text": "Sure! Here you go."]]), statusCode: 200)
        }
    }

    @Test func aQuestionThatGivesAwayTheAnswerIsCaught() {
        let card = CardScript.Card(question: "[...] is the drug of choice for absence seizures.", answer: "Ethosuximide", deckName: "")
        #expect(CardScript.givesAwayAnswer(.init(question: "Is ethosuximide the drug of choice?", answer: "Yes."), card: card))
        #expect(!CardScript.givesAwayAnswer(.init(question: "What's the drug of choice for absence seizures?", answer: "Ethosuximide."), card: card))

        let alreadyThere = CardScript.Card(question: "The [...] artery branches off the renal artery.", answer: "renal", deckName: "")
        #expect(!CardScript.givesAwayAnswer(.init(question: "Which artery branches off the renal artery?", answer: "The renal."), card: alreadyThere),
                "the word was in the question as written")
    }

    // MARK: - Several lines in one recording

    @Test func severalLinesAreReadAsParagraphsWithAPauseAsked() throws {
        let request = try GeminiSpeech.makeRequest(lines: ["What's the drug of choice?", "Ethosuximide", "Line\none"], voice: "Kore", apiKey: "k")
        let json = try body(of: request)
        let contents = try #require(json["contents"] as? [[String: Any]])
        let part = try #require((contents.first?["parts"] as? [[String: Any]])?.first)
        #expect(part["text"] as? String == "What's the drug of choice?\n\nEthosuximide.\n\nLine one.")
        #expect((part["speechMetadata"] as? [String: Any])?["style"] as? String == GeminiSpeech.togetherStyle)
    }

    private let lines = [
        "What's the drug of choice for absence seizures?",
        "Ethosuximide.",
        "Which nerve supplies the deltoid?",
        "The axillary nerve.",
    ]

    /// A recording at 1,000 samples a second: speech, as a loud tone, and
    /// pauses, as silence, with the words heard spread over each stretch
    /// of speech.
    private func recording(_ parts: [(seconds: Double, heard: [String]?)]) -> (RecordingSplitter.Sound, [RecordingSplitter.HeardWord]) {
        var samples: [Int16] = []
        var heard: [RecordingSplitter.HeardWord] = []
        var time = 0.0
        for part in parts {
            let count = Int((part.seconds * 1_000).rounded())
            if let words = part.heard {
                samples += (0..<count).map { (index: Int) -> Int16 in index % 2 == 0 ? 3_000 : -3_000 }
                let each = part.seconds / Double(max(words.count, 1))
                for (index, word) in words.enumerated() {
                    heard.append(.init(text: word, start: time + Double(index) * each, end: time + Double(index + 1) * each))
                }
            } else {
                samples += [Int16](repeating: 0, count: count)
            }
            time += part.seconds
        }
        return (RecordingSplitter.Sound(samples: samples, sampleRate: 1_000), heard)
    }

    private func standardParts(
        answer: [String] = ["etho", "suck", "simide"],
        pauseAfterAnswer: Double = 0.6,
        last: [String] = ["the", "axillary", "nerve"]
    ) -> [(seconds: Double, heard: [String]?)] {
        [
            (0.2, nil),
            (0.8, ["what's", "the", "drug"]), (0.08, nil), (1.2, ["of", "choice", "for", "absence", "seizures"]),
            (0.6, nil),
            (0.8, answer),
            (pauseAfterAnswer, nil),
            (2.0, ["which", "nerve", "supplies", "the", "deltoid"]),
            (0.5, nil),
            (1.0, last),
            (0.3, nil),
        ]
    }

    /// A piece's start and end in the recording, in hundredths of a second.
    private func span(_ piece: RecordingSplitter.Piece, in sound: RecordingSplitter.Sound) -> [Int]? {
        guard let cut = piece.sound,
              let start = (0...(sound.samples.count - cut.samples.count)).first(where: { offset in
                  // The fades change the very ends; the middle is as it was.
                  sound.samples[offset + 20..<offset + cut.samples.count - 20]
                      .elementsEqual(cut.samples[20..<cut.samples.count - 20])
              })
        else { return nil }
        return [start / 10, (start + cut.samples.count) / 10]
    }

    @Test func eachLineIsCutAtThePauseAfterIt() {
        let (sound, heard) = recording(standardParts())
        let pieces = RecordingSplitter.split(sound, lines: lines, heard: heard)
        #expect(pieces.allSatisfy { $0.problem == nil })
        // Each with its speech, a little quiet before and a little more
        // after, but not the short pause inside the first line.
        #expect(pieces.map { span($0, in: sound) } == [[5, 253], [273, 393], [413, 653], [663, 803]])
    }

    @Test func aPieceWhoseWordsDontMatchIsLeftOut() {
        let (sound, heard) = recording(standardParts(last: ["banana", "bread", "pudding"]))
        let pieces = RecordingSplitter.split(sound, lines: lines, heard: heard)
        #expect(pieces.prefix(3).allSatisfy { $0.problem == nil })
        #expect(pieces[3].problem?.hasPrefix("Its words didn’t match the line") == true)
    }

    @Test func linesRunTogetherWithoutAPauseAreLeftOut() {
        let (sound, heard) = recording(standardParts(pauseAfterAnswer: 0))
        let pieces = RecordingSplitter.split(sound, lines: lines, heard: heard)
        #expect(pieces.map { $0.problem == nil } == [true, false, false, true])
    }

    @Test func aLineSaidTwiceIsLeftOut() {
        let (sound, heard) = recording(standardParts(answer: ["ethosuximide", "ethosuximide"]))
        let pieces = RecordingSplitter.split(sound, lines: lines, heard: heard)
        #expect(pieces.map { $0.problem == nil } == [true, false, true, true])
    }

    @Test func aRecordingCutShortLeavesOutTheLinesItDoesntHave() {
        let (sound, heard) = recording(Array(standardParts().dropLast(3)))
        let pieces = RecordingSplitter.split(sound, lines: lines, heard: heard)
        #expect(pieces.map { $0.problem == nil } == [true, true, false, false])
    }

    @Test func aRecordingSurvivesTheTripThroughAWAVFile() {
        let sound = RecordingSplitter.Sound(samples: [0, 1, -1, 32_767, -32_768, 1_234], sampleRate: 24_000)
        #expect(RecordingSplitter.Sound(wav: sound.wav) == sound)
        #expect(RecordingSplitter.Sound(wav: Data("not a wav file".utf8)) == nil)
    }

    @Test func wordsHeardALittleWrongStillLineUp() {
        // "simide" is the likest to "ethosuximide"; the rest were extra.
        #expect(RecordingSplitter.align(["etho", "suck", "simide", "which"], to: ["ethosuximide", "which"]) == [nil, nil, 0, 1])
        #expect(RecordingSplitter.similarity("ethosucksimide", "ethosuximide") > 0.7)
        #expect(RecordingSplitter.similarity("", "") == 1)
        #expect(RecordingSplitter.similarity("abc", "") == 0)
    }
}
