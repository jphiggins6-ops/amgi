//
//  MnemonicImageGenerator.swift
//  MnemonicCore
//

public import Dependencies
public import Foundation

/// Encoded image bytes plus the extension its media file should carry.
public struct MnemonicImage: Sendable, Equatable {
    public var data: Data
    /// "png", "jpg" — becomes the media filename's extension.
    public var fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

public struct MnemonicImageRequest: Sendable, Equatable {
    /// What the user described.
    public var idea: String
    /// House style wrapped around every idea, so each prompt only has to say
    /// what's in the picture.
    public var style: String

    public init(idea: String, style: String = MnemonicPromptStyle.default) {
        self.idea = idea
        self.style = style
    }

    /// What a real image model should be sent.
    public var fullPrompt: String {
        style.isEmpty ? idea : "\(style)\n\nScene: \(idea)"
    }
}

public enum MnemonicPromptStyle {
    /// Tuned for memorability rather than beauty. "No text" matters: image
    /// models garble lettering, and a mnemonic with misspelled labels is
    /// worse than none.
    public static let `default` = """
        A simple, bold, memorable illustration for a flashcard mnemonic. \
        One clear subject, exaggerated and slightly absurd so it sticks. \
        Plain white background. No text, letters, labels or numbers.
        """

    /// For pictures that explain rather than stick: what the thing looks
    /// like, where it is, how it works. Still no text, for the same reason.
    public static let diagram = """
        A clear, accurate educational illustration for a medical flashcard. \
        Show the structure, finding or mechanism plainly and realistically, \
        in a clean textbook style. Plain white background. \
        No text, letters, labels or numbers.
        """
}

/// THE HOOK: the one place a picture gets made.
///
/// Everything else — capture, the review list, approval — only ever calls
/// `generate`. `liveValue` is `.automatic`: OpenAI when a key is saved,
/// the placeholder otherwise. Another image service would be one more
/// factory here; no screen changes.
public struct MnemonicImageGenerator: Sendable {
    public var generate: @Sendable (_ request: MnemonicImageRequest) async throws -> MnemonicImage

    public init(generate: @escaping @Sendable (_ request: MnemonicImageRequest) async throws -> MnemonicImage) {
        self.generate = generate
    }
}

extension MnemonicImageGenerator {
    /// A coloured square with the idea written on it — a new colour every
    /// time, so "Try again" visibly does something. Pauses briefly so the
    /// loading state gets exercised the way a real model would exercise it.
    /// Costs nothing, needs no account, touches no network.
    public static let placeholder = MnemonicImageGenerator { request in
        try await Task.sleep(for: .milliseconds(1200))
        let hue = Double(Int.random(in: 0..<360)) / 360
        let data = try await PlaceholderImageRenderer.render(caption: request.idea, hue: hue)
        return MnemonicImage(data: data, fileExtension: "png")
    }
}

extension MnemonicImageGenerator {
    /// OpenAI's image API. The picture comes back as a 1024 px image and is
    /// shrunk to a 768 px JPEG before anything else sees it.
    public static func openAI(
        apiKey: String,
        model: String,
        quality: MnemonicSettings.Quality
    ) -> MnemonicImageGenerator {
        MnemonicImageGenerator { request in
            let raw = try await OpenAIImageClient.generate(
                prompt: request.fullPrompt,
                apiKey: apiKey,
                model: model,
                quality: quality
            )
            return await MnemonicImageProcessing.finalize(raw)
        }
    }

    /// Real pictures when an OpenAI key is saved, free placeholders when
    /// not. Decided on every call, so saving or removing a key takes effect
    /// immediately, with no restart.
    public static let automatic = MnemonicImageGenerator { request in
        guard let apiKey = MnemonicAPIKey.load() else {
            return try await MnemonicImageGenerator.placeholder.generate(request)
        }
        return try await MnemonicImageGenerator.openAI(
            apiKey: apiKey,
            model: MnemonicSettings.model,
            quality: MnemonicSettings.quality
        ).generate(request)
    }
}

extension MnemonicImageGenerator: DependencyKey {
    public static let liveValue = MnemonicImageGenerator.automatic
    public static let testValue = MnemonicImageGenerator { _ in
        throw MnemonicError.unimplemented("MnemonicImageGenerator.generate")
    }
}

extension DependencyValues {
    public var mnemonicImageGenerator: MnemonicImageGenerator {
        get { self[MnemonicImageGenerator.self] }
        set { self[MnemonicImageGenerator.self] = newValue }
    }
}
