//
//  MnemonicImageServiceTests.swift
//  MnemonicCoreTests
//

import Foundation
import Testing
@testable import MnemonicCore

@Suite struct OpenAIImageClientTests {
    @Test func requestCarriesKeyModelQualityAndPrompt() throws {
        let request = try OpenAIImageClient.makeRequest(
            prompt: "a giant ice anchor", apiKey: "sk-test", model: "gpt-image-1.5", quality: .medium
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/generations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval >= 120, "slow-but-billed generations must not be cut off")

        let body = try JSONDecoder().decode(OpenAIImageClient.RequestBody.self, from: try #require(request.httpBody))
        #expect(body == OpenAIImageClient.RequestBody(
            model: "gpt-image-1.5", prompt: "a giant ice anchor", size: "1024x1024", quality: "medium", n: 1
        ))
    }

    @Test func requestSendsNoFormatParameters() throws {
        let request = try OpenAIImageClient.makeRequest(prompt: "x", apiKey: "k", model: "m", quality: .low)
        let json = try #require(String(data: try #require(request.httpBody), encoding: .utf8))
        #expect(!json.contains("output_format"))
        #expect(!json.contains("response_format"))
    }

    @Test func qualityRawValuesAreWhatTheAPIExpects() {
        #expect(MnemonicSettings.Quality.allCases.map(\.rawValue) == ["low", "medium", "high"])
    }

    @Test func successResponseYieldsTheDecodedBytes() throws {
        let body = Data(#"{"created":1,"data":[{"b64_json":"\#(Data("picture".utf8).base64EncodedString())"}]}"#.utf8)
        #expect(try OpenAIImageClient.imageData(from: body, statusCode: 200) == Data("picture".utf8))
    }

    @Test func errorResponseSurfacesOpenAIsOwnMessage() {
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-te***st.","type":"invalid_request_error"}}"#.utf8)
        #expect(throws: MnemonicError.imageService("Incorrect API key provided: sk-te***st.")) {
            try OpenAIImageClient.imageData(from: body, statusCode: 401)
        }
    }

    @Test func unreadableErrorFallsBackToTheStatusCode() {
        #expect(throws: MnemonicError.imageService("OpenAI answered with HTTP 502.")) {
            try OpenAIImageClient.imageData(from: Data("<html>bad gateway</html>".utf8), statusCode: 502)
        }
    }

    @Test func successWithoutAPictureIsAnError() {
        #expect(throws: MnemonicError.imageService("OpenAI didn't send a picture back.")) {
            try OpenAIImageClient.imageData(from: Data(#"{"data":[]}"#.utf8), statusCode: 200)
        }
    }
}

@Suite struct MnemonicImageProcessingTests {
    @Test func recognisesCommonImageFormats() {
        #expect(MnemonicImageProcessing.sniffExtension(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) == "png")
        #expect(MnemonicImageProcessing.sniffExtension(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(MnemonicImageProcessing.sniffExtension(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBP".utf8)) == "webp")
    }

    #if canImport(UIKit)
    @Test func finalizeReencodesAsJPEG() async throws {
        let png = try await PlaceholderImageRenderer.render(caption: "x", hue: 0.3)
        let image = await MnemonicImageProcessing.finalize(png)
        #expect(image.fileExtension == "jpg")
        #expect(Array(image.data.prefix(3)) == [0xFF, 0xD8, 0xFF])
    }
    #endif
}

@Suite struct MnemonicDraftCacheTests {
    private func scratchCache() -> MnemonicDraftCache {
        MnemonicDraftCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemonic-drafts-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func draftsRoundTripAndCanBeRemoved() {
        let cache = scratchCache()
        let draft = MnemonicDraft(image: MnemonicImage(data: Data([1, 2, 3]), fileExtension: "jpg"), prompt: "ice anchor")
        cache.save(draft, for: "1695000000000:ab12cd34ef")
        #expect(cache.load(for: "1695000000000:ab12cd34ef") == draft)

        cache.remove(for: "1695000000000:ab12cd34ef")
        #expect(cache.load(for: "1695000000000:ab12cd34ef") == nil)
    }

    @Test func draftsForDifferentIdeasDoNotCollide() {
        let cache = scratchCache()
        let first = MnemonicDraft(image: MnemonicImage(data: Data([1]), fileExtension: "jpg"), prompt: "one")
        let second = MnemonicDraft(image: MnemonicImage(data: Data([2]), fileExtension: "png"), prompt: "two")
        cache.save(first, for: "1:a")
        cache.save(second, for: "1:b")
        #expect(cache.load(for: "1:a") == first)
        #expect(cache.load(for: "1:b") == second)
    }

    @Test func filenamesAreSafe() {
        let name = scratchCache().fileBase(for: "1695000000000:ab/../x").lastPathComponent
        #expect(name == "1695000000000_ab____x")
    }
}
