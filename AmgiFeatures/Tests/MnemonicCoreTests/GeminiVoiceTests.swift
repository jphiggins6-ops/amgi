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
        let bad = Data(#"{"error":{"code":429,"message":"Resource has been exhausted.","status":"RESOURCE_EXHAUSTED"}}"#.utf8)
        #expect(throws: CardVoiceError.service("Resource has been exhausted.")) {
            try GeminiSpeech.wav(from: bad, statusCode: 429)
        }
        #expect(throws: CardVoiceError.service("Gemini sent back no audio.")) {
            try GeminiSpeech.wav(from: try response(parts: [["text": "hello"]]), statusCode: 200)
        }
        let blocked = Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)
        #expect(throws: CardVoiceError.service("Gemini turned this card down (SAFETY).")) {
            try GeminiSpeech.wav(from: blocked, statusCode: 200)
        }
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
}
