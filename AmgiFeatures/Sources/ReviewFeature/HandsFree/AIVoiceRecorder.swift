//
//  AIVoiceRecorder.swift
//  ReviewFeature
//

import Dependencies
public import Foundation
public import Observation
import OSLog
import AppCore
import MnemonicCore
import ReviewCore
#if canImport(UIKit)
import Speech
#endif

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

    /// Lets new work start again before a limit has passed: billing
    /// turned on, say.
    static func clearPause() {
        pause = nil
        UserDefaults.standard.removeObject(forKey: pausedUntilKey)
        UserDefaults.standard.removeObject(forKey: pauseReasonKey)
        UserDefaults.standard.removeObject(forKey: pausedAtKey)
    }

    /// When Google last said the day's limit was reached, while that
    /// holds; nil when it isn't known.
    static var dailyLimitReachedAt: Date? {
        let at = UserDefaults.standard.double(forKey: pausedAtKey)
        return at > 0 ? Date(timeIntervalSince1970: at) : nil
    }

    private static let pausedUntilKey = "ai_voice_paused_until"
    private static let pauseReasonKey = "ai_voice_pause_reason"
    private static let pausedAtKey = "ai_voice_paused_at"

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
        let log = CardVoiceLog.shared
        let label = CardVoiceLog.quote(card.question)
        making[key] = Task {
            do {
                let lines = try await self.script(for: card, rewrites: rewrites)
                // The question first: it's read first.
                let sides = [("question", lines.question), ("answer", lines.answer)]
                for (side, text) in sides
                where !text.isEmpty && CardVoiceRecordings.recording(of: text, voice: voice) == nil {
                    log.add("Recording the \(side) of \(label)")
                    let wav = try await client.record(text, voice)
                    try CardVoiceRecordings.save(wav: wav, of: text, voice: voice)
                    log.countRecording()
                }
                log.add("Ready: \(label)", .done)
                #if canImport(UIKit)
                if self.isReady(card, voice: voice, rewrites: rewrites) {
                    CardVoicePreparation.shared.cardVoiced(voice: voice, rewrites: rewrites)
                }
                #endif
                problem = nil
                lastError = nil
            } catch {
                problem = error.localizedDescription
                lastError = error
                Self.pauseIfLimited(error)
                if case .limited? = error as? CardVoiceError {
                    log.add("Google’s limit, at \(label): \(error.localizedDescription)", .waiting)
                } else {
                    log.add("Couldn’t do \(label): \(error.localizedDescription)", .problem)
                }
                Log.review.error("The AI voice couldn't do a card: \(error.localizedDescription)")
            }
            making[key] = nil
        }
    }

    /// The card's script: written now, when there isn't one (with
    /// `rewrites`), and kept.
    func script(for card: VoiceCard, rewrites: Bool) async throws -> CardScript.Lines {
        if let known = lines(for: card, rewrites: rewrites) { return known }
        let log = CardVoiceLog.shared
        log.add("Writing the script for \(CardVoiceLog.quote(card.question))")
        let script = try await client.script(card.written)
        try CardVoiceRecordings.save(script, for: card.written)
        let checked = self.checked(script, card)
        scripts[CardVoiceRecordings.scriptFile(for: card.written)] = checked
        log.add("Script written: \(CardVoiceLog.quote(checked.question))")
        return checked
    }

    /// Errors that hold up every card alike: Google's limit, no
    /// connection, no key.
    static func stops(_ error: any Error) -> Bool {
        if error is URLError { return true }
        switch error as? CardVoiceError {
        case .limited?, .noKey?: return true
        default: return false
        }
    }

    /// Holds new work back when Google says the key's limit is reached:
    /// for a minute, or until its day ends at midnight in California.
    private static func pauseIfLimited(_ error: any Error) {
        guard case .limited(_, let daily, let limit)? = error as? CardVoiceError else { return }
        if daily {
            CardVoiceLog.shared.noteDailyLimit(limit)
        }
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
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: pausedAtKey)
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
            let log = CardVoiceLog.shared
            making[key] = Task {
                do {
                    log.add("Recording a sample in \(voice)")
                    let wav = try await client.record(text, voice)
                    try CardVoiceRecordings.save(wav: wav, of: text, voice: voice)
                    log.countRecording()
                    log.add("Sample ready", .done)
                    problem = nil
                } catch {
                    problem = error.localizedDescription
                    Self.pauseIfLimited(error)
                    log.add("Couldn’t record the sample: \(error.localizedDescription)", .problem)
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

// MARK: - What it's been doing

/// What the AI voice has been doing, newest first, for Settings → Review →
/// AI Voice → Activity: each card's steps, each card made ready, and each
/// refusal from Google in its own words. The last 300 entries are kept
/// between launches, with today's count of recordings (Google counts its
/// days in California) and the daily limit Google last gave for the key.
@MainActor
@Observable
public final class CardVoiceLog {
    public static let shared = CardVoiceLog()

    public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Under way.
            case step
            case done
            /// Held up by Google's limits, or waiting its turn.
            case waiting
            case problem
        }

        public let id: UUID
        public let date: Date
        public let kind: Kind
        public let text: String
    }

    public private(set) var entries: [Entry] = []
    /// Recordings made today, by Google's day.
    public private(set) var recordingsToday = 0
    /// The daily limit Google last said the key has, when it said.
    public private(set) var dailyLimit: Int?

    private init() {
        entries = Self.loadEntries()
        let defaults = UserDefaults.standard
        dailyLimit = defaults.object(forKey: Self.dailyLimitKey) as? Int
        refresh()
    }

    func add(_ text: String, _ kind: Entry.Kind = .step) {
        entries.insert(Entry(id: UUID(), date: Date(), kind: kind, text: text), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        saveEntries()
    }

    public func clear() {
        entries = []
        saveEntries()
    }

    /// The whole log as text, oldest first, to copy.
    public var asText: String {
        entries.reversed()
            .map { "\($0.date.formatted(date: .abbreviated, time: .standard))  \($0.text)" }
            .joined(separator: "\n")
    }

    /// Today's count, from nothing again once Google's day has turned.
    public func refresh() {
        let defaults = UserDefaults.standard
        recordingsToday = defaults.string(forKey: Self.usageDayKey) == Self.googleDay()
            ? defaults.integer(forKey: Self.usageCountKey)
            : 0
    }

    func countRecording() {
        let defaults = UserDefaults.standard
        let today = Self.googleDay()
        if defaults.string(forKey: Self.usageDayKey) != today {
            defaults.set(today, forKey: Self.usageDayKey)
            recordingsToday = 0
        }
        recordingsToday += 1
        defaults.set(recordingsToday, forKey: Self.usageCountKey)
        // Past the limit Google gave: it's been raised, billing turned on, say.
        if let limit = dailyLimit, recordingsToday > limit {
            dailyLimit = nil
            defaults.removeObject(forKey: Self.dailyLimitKey)
        }
    }

    func noteDailyLimit(_ limit: Int?) {
        guard let limit else { return }
        dailyLimit = limit
        UserDefaults.standard.set(limit, forKey: Self.dailyLimitKey)
    }

    /// A card's text in quotes, cut short when long.
    static func quote(_ text: String) -> String {
        let short = text.count > 70 ? String(text.prefix(69)) + "…" : text
        return "“\(short)”"
    }

    /// The date in California, where Google's day is counted: "2026-10-05".
    static func googleDay(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    private static let maxEntries = 300
    private static let usageDayKey = "ai_voice_usage_day"
    private static let usageCountKey = "ai_voice_usage_count"
    private static let dailyLimitKey = "ai_voice_daily_limit"

    private static var file: URL {
        URL.applicationSupportDirectory.appending(path: "CardVoiceActivity.json")
    }

    private static func loadEntries() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func saveEntries() {
        let file = Self.file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}

#if canImport(UIKit)
// MARK: - Several lines in one recording

/// What became of a card made ready along with others.
enum CardOutcome: Equatable, Sendable {
    case ready
    /// It couldn't be done: its script, or a recording of it, failed.
    case failed
    /// Held up, by Google's limit, the connection or the lack of a key,
    /// before it was done: it can be tried again.
    case notDone
}

/// How lines recorded together came out.
struct TogetherOutcome: Sendable {
    /// Each line cut out cleanly, and where its recording was kept.
    var saved: [String: URL] = [:]
    /// Why each of the rest wasn't.
    var failed: [String: String] = [:]
    /// How long Gemini took to record them, in seconds.
    var seconds: Double = 0
}

extension AIVoiceRecorder {
    /// Makes several cards ready at once, for Prepare Cards: each one's
    /// script, then the lines still to record, read together in one
    /// recording and cut apart, when the phone can check the pieces
    /// (`SpokenCheck`). A line whose piece doesn't pass the check, and
    /// every line when the phone can't check, is recorded on its own, as
    /// before. Stops at Google's limit or a dropped connection, leaving
    /// the cards not yet done for later.
    func make(_ cards: [VoiceCard], voice: String, rewrites: Bool) async -> [CardOutcome] {
        let log = CardVoiceLog.shared
        var outcomes = cards.map { isReady($0, voice: voice, rewrites: rewrites) ? CardOutcome.ready : .notDone }
        let wasReady = outcomes.map { $0 == .ready }
        if Self.isPaused {
            problem = Self.pause?.reason
            return outcomes
        }
        var stopped = false
        var hadProblem = false

        var toRecord: [String] = []
        for index in cards.indices where outcomes[index] == .notDone {
            do {
                let lines = try await script(for: cards[index], rewrites: rewrites)
                for line in [lines.question, lines.answer]
                where !line.isEmpty && !toRecord.contains(line) && CardVoiceRecordings.recording(of: line, voice: voice) == nil {
                    toRecord.append(line)
                }
            } catch {
                note(error, at: CardVoiceLog.quote(cards[index].question))
                hadProblem = true
                if Self.stops(error) {
                    stopped = true
                    break
                }
                outcomes[index] = .failed
            }
        }

        var onTheirOwn = toRecord
        if !stopped, toRecord.count > 1 {
            if SpokenCheck.isAvailable {
                log.add("Recording \(toRecord.count) lines together, for \(cards.count) \(cards.count == 1 ? "card" : "cards")")
                do {
                    let outcome = try await recordTogether(toRecord, voice: voice)
                    onTheirOwn = toRecord.filter { outcome.saved[$0] == nil }
                    let cut = toRecord.count - onTheirOwn.count
                    log.add("Cut apart: \(cut) of \(toRecord.count) lines passed the check", cut == toRecord.count ? .done : .step)
                    for line in onTheirOwn {
                        log.add("Left out \(CardVoiceLog.quote(line)): \(outcome.failed[line] ?? "")")
                    }
                } catch {
                    note(error, at: "the lines recorded together")
                    if Self.stops(error) {
                        stopped = true
                    }
                }
            } else {
                log.add("The iPhone’s speech recognition isn’t allowed or isn’t on the phone, so each side is recorded on its own", .waiting)
            }
        }
        if !stopped {
            for line in onTheirOwn {
                log.add("Recording on its own: \(CardVoiceLog.quote(line))")
                do {
                    let wav = try await client.record(line, voice)
                    try CardVoiceRecordings.save(wav: wav, of: line, voice: voice)
                    log.countRecording()
                } catch {
                    note(error, at: CardVoiceLog.quote(line))
                    hadProblem = true
                    if Self.stops(error) {
                        stopped = true
                        break
                    }
                }
            }
        }

        for index in cards.indices where outcomes[index] == .notDone {
            if isReady(cards[index], voice: voice, rewrites: rewrites) {
                outcomes[index] = .ready
            } else if !stopped {
                outcomes[index] = .failed
            }
        }
        for index in cards.indices where outcomes[index] == .ready && !wasReady[index] {
            log.add("Ready: \(CardVoiceLog.quote(cards[index].question))", .done)
            CardVoicePreparation.shared.cardVoiced(voice: voice, rewrites: rewrites)
        }
        if !hadProblem && !stopped {
            problem = nil
            lastError = nil
        }
        return outcomes
    }

    /// `lines` read together in one recording, cut apart and each piece
    /// checked (`RecordingSplitter`), and the pieces that pass kept as a
    /// recording each: in the AI voice's folder, or in `place`. Throws
    /// when the recording can't be made, or can't be checked at all.
    func recordTogether(_ lines: [String], voice: String, into place: URL? = nil) async throws -> TogetherOutcome {
        let began = Date()
        let wav = try await client.recordTogether(lines, voice)
        CardVoiceLog.shared.countRecording()
        var outcome = TogetherOutcome()
        outcome.seconds = Date().timeIntervalSince(began)
        // A minute or so of sound to go through: off the main thread.
        let decoded = await Task.detached { () -> (sound: RecordingSplitter.Sound, phrases: [SpokenCheck.Phrase])? in
            guard let sound = RecordingSplitter.Sound(wav: wav) else { return nil }
            let phrases = RecordingSplitter.phrases(in: sound).map { phrase in
                SpokenCheck.Phrase(start: phrase.start, wav: sound.clip(from: phrase.start, to: phrase.end).wav)
            }
            return (sound: sound, phrases: phrases)
        }.value
        guard let decoded else {
            throw CardVoiceError.service("Gemini’s recording couldn’t be read to cut it apart.")
        }
        let heard = try await SpokenCheck.words(in: decoded.phrases, hints: lines)
        CardVoiceLog.shared.add("Heard \(heard.count) words in \(decoded.phrases.count) stretches of speech, for \(lines.count) lines")
        let sound = decoded.sound
        let pieces = await Task.detached {
            RecordingSplitter.split(sound, lines: lines, heard: heard)
        }.value
        for (line, piece) in zip(lines, pieces) {
            if let cut = piece.sound {
                outcome.saved[line] = try CardVoiceRecordings.save(wav: cut.wav, of: line, voice: voice, in: place)
            } else {
                outcome.failed[line] = piece.problem ?? "It couldn’t be cut out."
            }
        }
        return outcome
    }

    /// Keeps a card's problem, and holds new work back at Google's limit.
    private func note(_ error: any Error, at label: String) {
        problem = error.localizedDescription
        lastError = error
        Self.pauseIfLimited(error)
        if case .limited? = error as? CardVoiceError {
            CardVoiceLog.shared.add("Google’s limit, at \(label): \(error.localizedDescription)", .waiting)
        } else {
            CardVoiceLog.shared.add("Couldn’t do \(label): \(error.localizedDescription)", .problem)
        }
        Log.review.error("The AI voice couldn't do a card: \(error.localizedDescription)")
    }
}

/// The phone's own speech recognition, run over a recording to hear which
/// words it says and when, so that a recording of several lines can be
/// cut apart and each piece checked (`RecordingSplitter`). On the phone
/// only: nothing is sent anywhere.
enum SpokenCheck {
    enum Failure: LocalizedError {
        case unavailable
        case tookTooLong

        var errorDescription: String? {
            switch self {
            case .unavailable: "The iPhone’s speech recognition isn’t available to check the recording."
            case .tookTooLong: "Checking the recording took too long."
            }
        }
    }

    private static let locale = Locale(identifier: "en-US")

    /// Whether recordings can be checked: speech recognition is allowed,
    /// and works on the phone.
    static var isAvailable: Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: locale)
        else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    /// Asks, the first time, to use speech recognition.
    static func requestPermission() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization(resuming(continuation))
        }
        return status == .authorized
    }

    /// A stretch of a recording (`RecordingSplitter.phrases`) as a WAV
    /// file, and where it starts in the recording, in seconds.
    struct Phrase: Sendable {
        let start: Double
        let wav: Data
    }

    /// The words heard in a recording, and when each was said, heard a
    /// stretch at a time: given a long recording whole, speech recognition
    /// can lose what came before a long pause. A stretch where nothing is
    /// heard adds no words.
    static func words(in phrases: [Phrase], hints: [String]) async throws -> [RecordingSplitter.HeardWord] {
        var heard: [RecordingSplitter.HeardWord] = []
        for phrase in phrases {
            let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
            try phrase.wav.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                for word in try await words(in: file, hints: hints) {
                    heard.append(RecordingSplitter.HeardWord(
                        text: word.text,
                        start: word.start + phrase.start,
                        end: word.end + phrase.start
                    ))
                }
            } catch let failure as Failure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Nothing heard in it: its lines fail the check.
                continue
            }
        }
        return heard
    }

    /// The words heard in `file`, and when each was said. `hints`, the
    /// lines it should say, help with words recognition doesn't know.
    static func words(in file: URL, hints: [String]) async throws -> [RecordingSplitter.HeardWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable
        else { throw Failure.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = false
        request.contextualStrings = unusualWords(in: hints)
        let recognition = Recognition(recognizer)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RecordingSplitter.HeardWord], any Error>) in
                recognition.start(request, continuation)
            }
        } onCancel: {
            recognition.stop(CancellationError())
        }
    }

    /// The lines' longer words, which recognition is likelier to get
    /// wrong: drug names and the like.
    static func unusualWords(in lines: [String]) -> [String] {
        var seen: Set<String> = []
        var found: [String] = []
        for word in lines.flatMap(RecordingSplitter.words) where word.count >= 6 && seen.insert(word).inserted {
            found.append(word)
        }
        return Array(found.prefix(100))
    }

    private static func resuming(
        _ continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>
    ) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { status in continuation.resume(returning: status) }
    }
}

/// One recognition of a file, from its start to its one answer, which
/// comes on speech recognition's own thread.
private final class Recognition: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<[RecordingSplitter.HeardWord], any Error>?
    private var stopped = false

    init(_ recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    func start(
        _ request: SFSpeechURLRecognitionRequest,
        _ continuation: CheckedContinuation<[RecordingSplitter.HeardWord], any Error>
    ) {
        let goes = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            self.continuation = continuation
            return true
        }
        guard goes else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(self))
        lock.withLock { self.task = task }
        Self.timeOut(self)
    }

    func stop(_ error: any Error) {
        let task = lock.withLock { () -> SFSpeechRecognitionTask? in
            stopped = true
            return self.task
        }
        task?.cancel()
        finish(.failure(error))
    }

    func finish(_ result: Result<[RecordingSplitter.HeardWord], any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<[RecordingSplitter.HeardWord], any Error>? in
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }

    private static func handler(_ recognition: Recognition) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            if let result, result.isFinal {
                let words = result.bestTranscription.segments.map { segment in
                    RecordingSplitter.HeardWord(
                        text: segment.substring,
                        start: segment.timestamp,
                        end: segment.timestamp + segment.duration
                    )
                }
                recognition.finish(.success(words))
            } else if let error {
                recognition.finish(.failure(error))
            }
        }
    }

    /// A couple of minutes is far longer than a recording of a few cards
    /// takes.
    private static func timeOut(_ recognition: Recognition) {
        Task {
            try? await Task.sleep(for: .seconds(120))
            recognition.stop(SpokenCheck.Failure.tookTooLong)
        }
    }
}
#endif
