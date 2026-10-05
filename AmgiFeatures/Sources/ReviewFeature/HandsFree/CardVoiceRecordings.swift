//
//  CardVoiceRecordings.swift
//  ReviewFeature
//

import CryptoKit
import Foundation
import MnemonicCore

/// The AI voice's recordings of card text, kept on the phone so that each
/// is made, and paid for, once. One file per text and voice, named by a
/// hash of both, in Application Support rather than Caches, which iOS
/// empties when space runs low (that would mean paying again), and left out
/// of iCloud backups.
public enum CardVoiceRecordings {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "CardVoices", directoryHint: .isDirectory)
    }

    /// Where the recording of `text` in `voice` is kept, made or not.
    static func file(for text: String, voice: String) -> URL {
        let name = [OpenAISpeech.model, OpenAISpeech.style, voice, text].joined(separator: "\n")
        let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: hash + ".mp3")
    }

    static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    static func save(_ audio: Data, to file: URL) throws {
        if !exists(folder) {
            var directory = folder
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        try audio.write(to: file, options: .atomic)
    }

    /// Drops a recording that won't play, so it's made again.
    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    /// The space the recordings take, in bytes.
    public static func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Deletes every recording. Cards are recorded again, and paid for
    /// again, as they're read.
    public static func deleteAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}
