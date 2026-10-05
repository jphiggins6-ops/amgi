//
//  AIVoiceRecorder.swift
//  ReviewFeature
//

import Dependencies
import Foundation
import OSLog
import AppCore
import MnemonicCore
import ReviewCore

/// A card as the AI voice reads it: its sides as written, for Gemini to
/// rewrite, and as the iPhone voice reads them, for when there's no script.
struct VoiceCard: Sendable {
    let written: CardScript.Card
    let question: String
    let answer: String

    /// The card from its rendered sides, the way hands-free mode reads
    /// them, so a card made ready ahead is the one read later.
    init(front: String, back: String, deckName: String) {
        written = CardScript.Card(
            question: SpokenCardText.questionAsWritten(fromHTML: front),
            answer: SpokenCardText.answerAsWritten(fromHTML: back),
            deckName: deckName
        )
        question = Self.speakable(SpokenCardText.question(fromHTML: front))
        answer = Self.speakable(SpokenCardText.answer(fromHTML: back))
    }

    static func speakable(_ text: String) -> String {
        text.isEmpty ? "Nothing to read on this side." : text
    }
}

enum CardSide: Sendable {
    case question, answer
}

/// Does the AI voice's work for each card (`CardVoiceRecordings`), once:
/// Gemini rewrites the card the way a tutor would say it, unless that's
/// switched off, then reads each side aloud. Waits for a recording when
/// one is wanted straight away.
@MainActor
final class AIVoiceRecorder {
    private let client: CardVoiceClient
    /// Work under way, by card (or line) and voice.
    private var making: [String: Task<Void, Never>] = [:]
    /// Scripts read from disk or written this session.
    private var scripts: [URL: CardScript.Lines] = [:]
    /// Why the last card couldn't be done, until one is.
    private(set) var problem: String?
    /// The error behind `problem`.
    private(set) var lastError: (any Error)?

    /// While Google's limit for the key holds, for the minute or the day:
    /// no new work starts, so cards go straight to the iPhone voice. Shared
    /// by every recorder, as the limit is.
    private(set) static var pause: (until: Date, daily: Bool, reason: String)?

    static var isPaused: Bool {
        if let pause {
            if pause.until > Date() { return true }
            Self.pause = nil
        }
        // A daily limit outlasts the app: it holds until Google's day ends.
        let defaults = UserDefaults.standard
        let until = defaults.double(forKey: pausedUntilKey)
        guard until > Date().timeIntervalSince1970 else { return false }
        pause = (
            until: Date(timeIntervalSince1970: until),
            daily: true,
            reason: defaults.string(forKey: pauseReasonKey) ?? "Google’s daily limit for the Gemini voice is reached."
        )
        return true
    }

    private static let pausedUntilKey = "ai_voice_paused_until"
    private static let pauseReasonKey = "ai_voice_pause_reason"

    init() {
        @Dependency(\.cardVoice) var client
        self.client = client
    }

    /// Whether there's a Gemini key.
    var hasKey: Bool { client.hasKey() }

    /// What's said for each side: the script once it's written (with
    /// `rewrites`), the card as the iPhone voice reads it otherwise.
    func lines(for card: VoiceCard, rewrites: Bool) -> CardScript.Lines? {
        guard rewrites else { return CardScript.Lines(question: card.question, answer: card.answer) }
        let file = CardVoiceRecordings.scriptFile(for: card.written)
        if let known = scripts[file] { return known }
        guard let saved = CardVoiceRecordings.script(for: card.written) else { return nil }
        let lines = checked(saved, card)
        scripts[file] = lines
        return lines
    }

    /// The text of a side, to be read in the iPhone's voice when there's no
    /// recording: the script reads better than the card, when there is one.
    func text(of side: CardSide, for card: VoiceCard, rewrites: Bool) -> String {
        let lines = lines(for: card, rewrites: rewrites) ?? CardScript.Lines(question: card.question, answer: card.answer)
        return side == .question ? lines.question : lines.answer
    }

    /// The recording of a side, once it's made.
    func recording(of side: CardSide, for card: VoiceCard, voice: String, rewrites: Bool) -> URL? {
        guard let lines = lines(for: card, rewrites: rewrites) else { return nil }
        return CardVoiceRecordings.recording(of: side == .question ? lines.question : lines.answer, voice: voice)
    }

    /// Whether both sides of the card are recorded.
    func isReady(_ card: VoiceCard, voice: String, rewrites: Bool) -> Bool {
        recording(of: .question, for: card, voice: voice, rewrites: rewrites) != nil
            && recording(of: .answer, for: card, voice: voice, rewrites: rewrites) != nil
    }

    /// Makes the card's script and recordings, and says whether both
    /// sides are recorded after.
    func make(_ card: VoiceCard, voice: String, rewrites: Bool) async -> Bool {
        prepare(card, voice: voice, rewrites: rewrites)
        await making[Self.key(card, voice: voice, rewrites: rewrites)]?.value
        return isReady(card, voice: voice, rewrites: rewrites)
    }

    /// Starts the card's script and recordings, unless they're made or
    /// under way, or Google's limit holds.
    func prepare(_ card: VoiceCard, voice: String, rewrites: Bool) {
        let key = Self.key(card, voice: voice, rewrites: rewrites)
        guard making[key] == nil, !isReady(card, voice: voice, rewrites: rewrites) else { return }
        if Self.isPaused {
            problem = Self.pause?.reason
            return
        }
        let client = self.client
        making[key] = Task {
            do {
                var lines = self.lines(for: card, rewrites: rewrites)
                if lines == nil {
                    let script = try await client.script(card.written)
                    try CardVoiceRecordings.save(script, for: card.written)
                    let checked = self.checked(script, card)
                    scripts[CardVoiceRecordings.scriptFile(for: card.written)] = checked
                    lines = checked
                }
                // The question first: it's read first.
                for text in [lines?.question, lines?.answer].compactMap({ $0 })
                where !text.isEmpty && CardVoiceRecordings.recording(of: text, voice: voice) == nil {
                    let wav = try await client.record(text, voice)
                    try CardVoiceRecordings.save(wav: wav, of: text, voice: voice)
                }
                problem = nil
                lastError = nil
            } catch {
                problem = error.localizedDescription
                lastError = error
                Self.pauseIfLimited(error)
                Log.review.error("The AI voice couldn't do a card: \(error.localizedDescription)")
            }
            making[key] = nil
        }
    }

    /// Holds new work back when Google says the key's limit is reached:
    /// for a minute, or until its day ends at midnight in California.
    private static func pauseIfLimited(_ error: any Error) {
        guard case .limited(_, let daily)? = error as? CardVoiceError else { return }
        let now = Date()
        var until = now.addingTimeInterval(60)
        if daily {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
                until = calendar.startOfDay(for: tomorrow)
            }
        }
        pause = (until: until, daily: daily, reason: error.localizedDescription)
        if daily {
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: pausedUntilKey)
            UserDefaults.standard.set(error.localizedDescription, forKey: pauseReasonKey)
        }
    }

    /// The recording of a side, waiting up to `limit` for the card's work
    /// under way; with `make`, it's started when there's none. Nil when it
    /// isn't there in time, though the work carries on, for next time.
    func recording(
        of side: CardSide,
        for card: VoiceCard,
        voice: String,
        rewrites: Bool,
        make: Bool,
        waitingAtMost limit: Duration
    ) async -> URL? {
        if let file = recording(of: side, for: card, voice: voice, rewrites: rewrites) { return file }
        if make { prepare(card, voice: voice, rewrites: rewrites) }
        let key = Self.key(card, voice: voice, rewrites: rewrites)
        let deadline = ContinuousClock.now.advanced(by: limit)
        while making[key] != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if let file = recording(of: side, for: card, voice: voice, rewrites: rewrites) { return file }
        }
        return recording(of: side, for: card, voice: voice, rewrites: rewrites)
    }

    /// A line on its own, such as Settings' sample, recorded as it is.
    func recording(ofLine text: String, voice: String, waitingAtMost limit: Duration) async -> URL? {
        if let file = CardVoiceRecordings.recording(of: text, voice: voice) { return file }
        if Self.isPaused {
            problem = Self.pause?.reason
            return nil
        }
        let key = "line\n\(voice)\n\(text)"
        if making[key] == nil {
            let client = self.client
            making[key] = Task {
                do {
                    let wav = try await client.record(text, voice)
                    try CardVoiceRecordings.save(wav: wav, of: text, voice: voice)
                    problem = nil
                } catch {
                    problem = error.localizedDescription
                    Self.pauseIfLimited(error)
                }
                making[key] = nil
            }
        }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while making[key] != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return CardVoiceRecordings.recording(of: text, voice: voice)
    }

    /// The script with the card's own text in place of an empty side, or
    /// of a question that gives the answer away.
    private func checked(_ script: CardScript.Lines, _ card: VoiceCard) -> CardScript.Lines {
        let question = script.question.isEmpty || CardScript.givesAwayAnswer(script, card: card.written)
            ? card.question
            : script.question
        return CardScript.Lines(question: question, answer: script.answer.isEmpty ? card.answer : script.answer)
    }

    private static func key(_ card: VoiceCard, voice: String, rewrites: Bool) -> String {
        [
            CardVoiceRecordings.scriptFile(for: card.written).lastPathComponent,
            card.question, card.answer, voice, rewrites ? "script" : "as is",
        ].joined(separator: "\n")
    }
}
