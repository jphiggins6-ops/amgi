//
//  MnemonicDraftCache.swift
//  MnemonicCore
//

public import Foundation

public struct MnemonicDraft: Sendable, Equatable {
    public var image: MnemonicImage
    /// The description that produced `image`.
    public var prompt: String

    public init(image: MnemonicImage, prompt: String) {
        self.image = image
        self.prompt = prompt
    }
}

/// Draft pictures on disk, so leaving the Mnemonics screen (or the app)
/// doesn't throw away a picture that has already been paid for. Application
/// Support rather than Caches: iOS purges Caches under storage pressure.
public struct MnemonicDraftCache: Sendable {
    let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("amgi-mnemonic-drafts", isDirectory: true)
    }

    private struct Meta: Codable {
        let prompt: String
        let fileExtension: String
    }

    public func save(_ draft: MnemonicDraft, for id: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = fileBase(for: id)
        guard (try? draft.image.data.write(to: base.appendingPathExtension("img"), options: .atomic)) != nil,
              let meta = try? JSONEncoder().encode(Meta(prompt: draft.prompt, fileExtension: draft.image.fileExtension))
        else { return }
        try? meta.write(to: base.appendingPathExtension("json"), options: .atomic)
    }

    public func load(for id: String) -> MnemonicDraft? {
        let base = fileBase(for: id)
        guard let metaData = try? Data(contentsOf: base.appendingPathExtension("json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
              let imageData = try? Data(contentsOf: base.appendingPathExtension("img"))
        else { return nil }
        return MnemonicDraft(image: MnemonicImage(data: imageData, fileExtension: meta.fileExtension), prompt: meta.prompt)
    }

    public func remove(for id: String) {
        let base = fileBase(for: id)
        try? FileManager.default.removeItem(at: base.appendingPathExtension("img"))
        try? FileManager.default.removeItem(at: base.appendingPathExtension("json"))
    }

    /// IDs look like "1695000000000:ab12cd34ef"; keep filenames to letters,
    /// digits and underscores.
    func fileBase(for id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(safe)
    }
}
