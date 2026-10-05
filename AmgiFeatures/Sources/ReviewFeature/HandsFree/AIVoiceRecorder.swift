//
//  AIVoiceRecorder.swift
//  ReviewFeature
//

import Dependencies
import Foundation
import OSLog
import AppCore
import MnemonicCore

/// Makes the AI voice's recordings of card text (`CardVoiceRecordings`),
/// each once, and waits for one when it's wanted straight away.
@MainActor
final class AIVoiceRecorder {
    private let client: CardVoiceClient
    /// Recordings under way, by the file each goes to.
    private var making: [URL: Task<Void, Never>] = [:]
    /// Why the last recording couldn't be made, until one is.
    private(set) var problem: String?

    init() {
        @Dependency(\.cardVoice) var client
        self.client = client
    }

    /// Whether there's an OpenAI key to record with.
    var hasKey: Bool { client.hasKey() }

    /// Starts recording `text` in `voice`, unless it's recorded already or
    /// under way.
    func prepare(_ text: String, voice: String) {
        let file = CardVoiceRecordings.file(for: text, voice: voice)
        guard making[file] == nil, !CardVoiceRecordings.exists(file) else { return }
        let client = self.client
        making[file] = Task {
            do {
                let audio = try await client.record(text, voice)
                try CardVoiceRecordings.save(audio, to: file)
                problem = nil
            } catch {
                problem = error.localizedDescription
                Log.review.error("The AI voice couldn't record: \(error.localizedDescription)")
            }
            making[file] = nil
        }
    }

    /// The recording of `text` in `voice`, waiting up to `limit` for one
    /// under way; with `make`, one is started when there's none. Nil when
    /// there's none in time, though one under way carries on, for next time.
    func recording(of text: String, voice: String, make: Bool, waitingAtMost limit: Duration) async -> URL? {
        let file = CardVoiceRecordings.file(for: text, voice: voice)
        if CardVoiceRecordings.exists(file) { return file }
        if make { prepare(text, voice: voice) }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while making[file] != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return CardVoiceRecordings.exists(file) ? file : nil
    }
}
