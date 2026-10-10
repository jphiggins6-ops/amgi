//
//  CardVoiceRecordings.swift
//  ReviewFeature
//

import AVFoundation
import CryptoKit
import Foundation
import MnemonicCore

/// The AI voice's work for each card, kept on the phone so that it's done,
/// and paid for, once: the script (`CardScript`, a small JSON file named by
/// a hash of the card's sides as written) and a recording of each line
/// (named by a hash of the line and the voice). In Application Support
/// rather than Caches, which iOS empties when space runs low (that would
/// mean paying again), and left out of iCloud backups.
public enum CardVoiceRecordings {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "CardVoices", directoryHint: .isDirectory)
    }

    // MARK: - Recordings

    /// The recording of `text` in `voice`, when there is one: in the AI
    /// voice's folder, or in `place`.
    static func recording(of text: String, voice: String, in place: URL? = nil) -> URL? {
        let name = hash(GeminiSpeech.model, GeminiSpeech.style, voice, text)
        let directory = place ?? folder
        return ["m4a", "wav"]
            .map { directory.appending(path: "\(name).\($0)") }
            .first(where: exists)
    }

    /// Keeps Gemini's WAV recording of `text` as AAC, a tenth of the size,
    /// or as the WAV itself when that can't be made: in the AI voice's
    /// folder, or in `place`.
    @discardableResult
    static func save(wav: Data, of text: String, voice: String, in place: URL? = nil) throws -> URL {
        let directory: URL
        if let place {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            directory = place
        } else {
            try makeFolder()
            directory = folder
        }
        let name = hash(GeminiSpeech.model, GeminiSpeech.style, voice, text)
        let compressed = directory.appending(path: "\(name).m4a")
        do {
            try writeAAC(fromWAV: wav, to: compressed)
            return compressed
        } catch {
            try? FileManager.default.removeItem(at: compressed)
            let file = directory.appending(path: "\(name).wav")
            try wav.write(to: file, options: .atomic)
            return file
        }
    }

    /// Where the test of recording several cards together keeps what it
    /// makes, apart from the AI voice's own recordings.
    static var testFolder: URL {
        URL.cachesDirectory.appending(path: "CardVoiceTest", directoryHint: .isDirectory)
    }

    static func clearTestFolder() {
        try? FileManager.default.removeItem(at: testFolder)
    }

    /// Drops a recording that won't play, so it's made again.
    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Scripts

    /// The script written for `card`, when there is one.
    static func script(for card: CardScript.Card) -> CardScript.Lines? {
        guard let data = try? Data(contentsOf: scriptFile(for: card)) else { return nil }
        return try? JSONDecoder().decode(CardScript.Lines.self, from: data)
    }

    static func save(_ lines: CardScript.Lines, for card: CardScript.Card) throws {
        try makeFolder()
        try JSONEncoder().encode(lines).write(to: scriptFile(for: card), options: .atomic)
    }

    /// Named by the card's sides alone: the deck can change without a new
    /// script.
    static func scriptFile(for card: CardScript.Card) -> URL {
        folder.appending(path: hash(CardScript.model, CardScript.version, card.question, card.answer) + ".json")
    }

    // MARK: - The folder

    /// The space the scripts and recordings take, in bytes.
    public static func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Deletes every script and recording. Cards are written and recorded
    /// again, and paid for again, as they're read.
    public static func deleteAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    private static func makeFolder() throws {
        guard !exists(folder) else { return }
        var directory = folder
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private static func hash(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// A WAV file's sound as AAC in an .m4a file.
    private static func writeAAC(fromWAV wav: Data, to file: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        try wav.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let source = try AVAudioFile(forReading: temporary)
        let format = source.processingFormat
        guard let sound = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try source.read(into: sound)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        // The file is finished when `output` goes, at the end of this.
        let output = try AVAudioFile(
            forWriting: file,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try output.write(from: sound)
    }
}
