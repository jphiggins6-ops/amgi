//
//  OpenAISpeechTests.swift
//  MnemonicCoreTests
//

import Foundation
import Testing
@testable import MnemonicCore

@Suite struct OpenAISpeechTests {
    @Test func theRequestAsksForTheTextInTheVoiceAsMP3() throws {
        let request = try OpenAISpeech.makeRequest(text: "Horner syndrome.", voice: "marin", apiKey: "sk-test")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let json = try #require(String(data: try #require(request.httpBody), encoding: .utf8))
        #expect(json.contains(#""response_format":"mp3""#))
        let body = try JSONDecoder().decode(OpenAISpeech.RequestBody.self, from: try #require(request.httpBody))
        #expect(body.model == OpenAISpeech.model)
        #expect(body.input == "Horner syndrome.")
        #expect(body.voice == "marin")
        #expect(body.instructions.contains("flashcard"))
    }

    @Test func overlongTextIsCutToWhatTheModelReads() throws {
        let text = String(repeating: "a", count: OpenAISpeech.maxInput + 10)
        let request = try OpenAISpeech.makeRequest(text: text, voice: "marin", apiKey: "sk-test")
        let body = try JSONDecoder().decode(OpenAISpeech.RequestBody.self, from: try #require(request.httpBody))
        #expect(body.input.count == OpenAISpeech.maxInput)
    }

    @Test func theAudioOrOpenAIsOwnErrorComesBack() throws {
        let audio = Data([0xFF, 0xFB, 0x90, 0x00])
        #expect(try OpenAISpeech.audio(from: audio, statusCode: 200) == audio)

        let bad = Data(#"{"error":{"message":"You exceeded your current quota."}}"#.utf8)
        #expect(throws: CardExplanationError.service("You exceeded your current quota.")) {
            try OpenAISpeech.audio(from: bad, statusCode: 429)
        }
        #expect(throws: CardExplanationError.service("OpenAI sent back no audio.")) {
            try OpenAISpeech.audio(from: Data(), statusCode: 200)
        }
    }
}
