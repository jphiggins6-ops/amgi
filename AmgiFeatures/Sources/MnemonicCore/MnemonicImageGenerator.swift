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
}

/// THE HOOK: the one place a picture gets made.
///
/// Everything else — capture, the review list, approval — only ever calls
/// `generate`. Swapping the placeholder for a real image model means
/// providing a different `liveValue` here; no screen changes.
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

extension MnemonicImageGenerator: DependencyKey {
    public static let liveValue = MnemonicImageGenerator.placeholder
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
