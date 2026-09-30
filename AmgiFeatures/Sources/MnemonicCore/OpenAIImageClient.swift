//
//  OpenAIImageClient.swift
//  MnemonicCore
//

import Foundation

/// One call to OpenAI's image endpoint. Request-building and
/// response-parsing are separate, pure functions so both are tested
/// without a network or a key.
///
/// No `output_format` / `output_compression`: some GPT image models have
/// been seen ignoring them, and `MnemonicImageProcessing` re-encodes
/// whatever comes back anyway.
enum OpenAIImageClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!

    struct RequestBody: Codable, Equatable {
        let model: String
        let prompt: String
        let size: String
        let quality: String
        let n: Int
    }

    static func makeRequest(
        prompt: String,
        apiKey: String,
        model: String,
        quality: MnemonicSettings.Quality
    ) throws -> URLRequest {
        // Generation routinely takes 20–60 s; the default 60 s would cut
        // off slow-but-successful calls that have already been billed.
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            prompt: prompt,
            size: "1024x1024",
            quality: quality.rawValue,
            n: 1
        ))
        return request
    }

    private struct SuccessBody: Decodable {
        struct Item: Decodable {
            let b64Json: String?
            enum CodingKeys: String, CodingKey { case b64Json = "b64_json" }
        }
        let data: [Item]
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    /// The picture bytes, or an error carrying OpenAI's own explanation
    /// ("Incorrect API key provided", "Billing hard limit reached", …).
    static func imageData(from body: Data, statusCode: Int) throws -> Data {
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error.message
            throw MnemonicError.imageService(message ?? "OpenAI answered with HTTP \(statusCode).")
        }
        guard let encoded = (try? JSONDecoder().decode(SuccessBody.self, from: body))?.data.first?.b64Json,
              let bytes = Data(base64Encoded: encoded)
        else {
            throw MnemonicError.imageService("OpenAI didn't send a picture back.")
        }
        return bytes
    }

    static func generate(
        prompt: String,
        apiKey: String,
        model: String,
        quality: MnemonicSettings.Quality
    ) async throws -> Data {
        let request = try makeRequest(prompt: prompt, apiKey: apiKey, model: model, quality: quality)
        let (body, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try imageData(from: body, statusCode: statusCode)
    }
}
