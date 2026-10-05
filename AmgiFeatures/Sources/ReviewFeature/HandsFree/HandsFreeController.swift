//
//  HandsFreeController.swift
//  ReviewFeature
//

#if canImport(UIKit)
import Foundation
import Observation
import AnkiKit
import AppCore
import MnemonicCore
import ReviewCore

/// Hands-free studying, for walking or a commute: each card is read aloud
/// and answered by voice.
///
/// The question is read; "show" turns the card over and reads just the
/// answer (the revealed cloze, never the Extra). A rating said on the
/// question side rates the card at once, without reading the answer. On
/// the answer side, "again", "hard", "good" or "easy" rates it and the next
/// card starts.
/// "Repeat" reads the side again, "undo" takes the last answer back, and
/// "stop" ends hands-free. Taps on the screen still work, and the reading
/// follows them. It carries on with the screen locked (the app's background
/// audio mode).
///
/// The cards chosen in Settings (`ReviewPreferences.aiVoiceCards`: all of
/// them, or those added since the AI voice started) are read in the AI
/// voice, from Google Gemini: the card is first rewritten the way a tutor
/// would say it (`CardScript`), then each side is recorded, the first time
/// it's read or ahead of time (`CardVoicePreparation`), the next card's
/// while this one is, and kept on the phone (`CardVoiceRecordings`), so
/// it's paid for once. Every other card is read in the iPhone's best
/// voice, for free, as is anything whose recording doesn't come in time.
@MainActor
@Observable
final class HandsFreeController {
    enum Phase: Equatable {
        case off
        case starting
        case readingQuestion
        case waitingToShow
        case readingAnswer
        case waitingForRating
        case finishing
    }

    private(set) var phase: Phase = .off
    /// The last command heard, e.g. "good".
    private(set) var lastHeard: String?
    /// Why hands-free stopped by itself, when it did.
    private(set) var problem: String?
    /// Why the AI voice couldn't record the last card, while the iPhone's
    /// voice reads in its place.
    private(set) var voiceProblem: String?

    var isOn: Bool { phase != .off }

    /// Made on first use: the review screen is rebuilt often, and most
    /// sessions never turn hands-free on.
    @ObservationIgnored private var voice: (speaker: CardSpeaker, listener: VoiceListener)?
    @ObservationIgnored private var madeRecorder: AIVoiceRecorder?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The reading and listening under way, so `stop()` can end it.
    @ObservationIgnored private var currentRace: Race?
    /// The AI voice, nil when it's switched off. Read as hands-free starts.
    @ObservationIgnored private var aiVoice: String?
    /// Whether cards are rewritten the way a tutor would say them first.
    @ObservationIgnored private var aiRewrites = true
    /// Cards added from this moment on are recorded in the AI voice (all
    /// of them with `AIVoiceCards.all`); nil when it's off or there's no
    /// Gemini key.
    @ObservationIgnored private var aiVoiceSince: Date?

    private var speaker: CardSpeaker { audio.speaker }
    private var listener: VoiceListener { audio.listener }

    private var audio: (speaker: CardSpeaker, listener: VoiceListener) {
        if let voice { return voice }
        let made = (speaker: CardSpeaker(), listener: VoiceListener())
        voice = made
        return made
    }

    private var recorder: AIVoiceRecorder {
        if let madeRecorder { return madeRecorder }
        let made = AIVoiceRecorder()
        madeRecorder = made
        return made
    }

    /// - Parameter finishMessage: said when the session runs out of cards.
    func start(session: ReviewSession, finishMessage: String) {
        guard loop == nil else { return }
        problem = nil
        lastHeard = nil
        phase = .starting
        loop = Task { [weak self] in
            await self?.run(session, finishMessage: finishMessage)
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        currentRace?.finish(.cancelled)
        currentRace = nil
        voice?.speaker.stop()
        voice?.listener.stop()
        if phase != .off {
            HandsFreeAudioSession.deactivate()
        }
        phase = .off
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: - The loop

    private enum Outcome: Sendable {
        case heard(VoiceCommand)
        /// The card changed or turned over some other way, by a tap.
        case changed
        /// Read to the end, when nothing was to be listened for after.
        case spoke
        case failed(String)
        case cancelled
    }

    private func run(_ session: ReviewSession, finishMessage: String) async {
        guard await HandsFreeAudioSession.requestPermission() else {
            end(problem: "Hands-free needs the microphone and speech recognition. Allow both for Amgi in the Settings app.")
            return
        }
        guard !Task.isCancelled else { return }
        do {
            try HandsFreeAudioSession.activate()
        } catch {
            end(problem: "The microphone couldn't start: \(error.localizedDescription)")
            return
        }
        speaker.speed = ReviewPreferences.handsFreeSpeed
        speaker.preferredVoice = ReviewPreferences.handsFreeVoice
        let aiCards = ReviewPreferences.aiVoiceCards
        aiVoice = aiCards == .off ? nil : ReviewPreferences.aiVoice.rawValue
        aiRewrites = ReviewPreferences.aiVoiceRewrites
        if aiVoice != nil && recorder.hasKey {
            aiVoiceSince = aiCards == .all ? .distantPast : ReviewPreferences.aiVoiceSince
        } else {
            aiVoiceSince = nil
        }
        voiceProblem = nil

        while !Task.isCancelled {
            if session.isFinished {
                show(.finishing)
                await speaker.speak(finishMessage)
                end(problem: nil)
                return
            }
            guard !session.isAdvancing, session.currentCardId != nil else {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            await waitForCardAudio(session)
            guard !Task.isCancelled else { return }

            let card = VoiceCard(front: session.frontHTML, back: session.backHTML, deckName: session.deckName)
            let recordsCard = recordsInAIVoice(session.currentCardId, card)
            if !session.showAnswer {
                show(.readingQuestion)
                if recordsCard, let aiVoice {
                    // The answer too, so it's ready by the time the card turns over.
                    recorder.prepare(card, voice: aiVoice, rewrites: aiRewrites)
                }
                prepareUpcomingCard(session)
                let question = Reading(side: .question, card: card, records: recordsCard)
                switch await speakThenListen(question, then: .waitingToShow, session: session, listenAfter: true) {
                case .heard(.reveal):
                    session.revealAnswer()
                case .heard(.rate(let rating)):
                    // Rated without hearing the answer: no need to read it.
                    session.revealAnswer()
                    await rate(rating, session)
                case .heard(.undo):
                    await undo(session)
                case .heard(.stop):
                    end(problem: nil)
                    return
                case .failed(let message):
                    end(problem: message)
                    return
                case .heard(.repeatSide), .changed, .spoke, .cancelled:
                    continue
                }
            } else {
                show(.readingAnswer)
                prepareUpcomingCard(session)
                let answer = Reading(side: .answer, card: card, records: recordsCard)
                switch await speakThenListen(answer, then: .waitingForRating, session: session, listenAfter: true) {
                case .heard(.rate(let rating)):
                    await rate(rating, session)
                case .heard(.undo):
                    await undo(session)
                case .heard(.stop):
                    end(problem: nil)
                    return
                case .heard(.reveal), .heard(.repeatSide):
                    // Read the answer again.
                    continue
                case .failed(let message):
                    end(problem: message)
                    return
                case .changed, .spoke, .cancelled:
                    continue
                }
            }
        }
    }

    /// Reads `text`, listening for a command: during the reading with
    /// headphones on, after it otherwise. With `listenAfter` off, reading
    /// to the end is itself the outcome. A tap that changes the card ends
    /// it early either way.
    ///
    /// The reading, the listening and the watch for taps race as plain
    /// tasks, and the first to finish wins (`Race`). A task group is the
    /// textbook way to write that, but Swift 6.2's region-based isolation
    /// checker rejects main-actor child tasks in one ("Pattern that the
    /// region-based isolation checker does not understand how to check").
    private func speakThenListen(
        _ reading: Reading,
        then waiting: Phase,
        session: ReviewSession,
        listenAfter: Bool
    ) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        let mark = SessionMark(session)
        let bargeIn = HandsFreeAudioSession.canListenWhileSpeaking
        let race = Race()
        currentRace = race

        race.add(Task {
            await self.read(reading)
            guard !race.isOver else { return }
            guard listenAfter else {
                race.finish(.spoke)
                return
            }
            self.show(waiting)
            guard !bargeIn, let heard = await self.hear() else { return }
            race.finish(heard)
        })
        if bargeIn {
            race.add(Task {
                if let heard = await self.hear() { race.finish(heard) }
            })
        }
        race.add(Task {
            while !race.isOver {
                if SessionMark(session) != mark {
                    race.finish(.changed)
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        })

        let outcome = await race.outcome()
        if currentRace === race { currentRace = nil }
        return outcome
    }

    /// The first of several tasks to finish decides the outcome; finishing
    /// cancels the rest, which stops their reading or listening.
    @MainActor
    private final class Race {
        private(set) var isOver = false
        private var result: Outcome?
        private var waiting: CheckedContinuation<Outcome, Never>?
        private var tasks: [Task<Void, Never>] = []

        func add(_ task: Task<Void, Never>) {
            if isOver {
                task.cancel()
            } else {
                tasks.append(task)
            }
        }

        func finish(_ outcome: Outcome) {
            guard !isOver else { return }
            isOver = true
            result = outcome
            for task in tasks { task.cancel() }
            tasks = []
            waiting?.resume(returning: outcome)
            waiting = nil
        }

        func outcome() async -> Outcome {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                waiting = continuation
            }
        }
    }

    /// Listens until a command is heard. Recognition stops by itself after
    /// a while, and after a silence, so it's started again until something
    /// is said; failing straight away again and again means it can't listen.
    private func hear() async -> Outcome? {
        var quickFailures = 0
        while !Task.isCancelled {
            let stream: AsyncThrowingStream<String, any Error>
            do {
                stream = try listener.start()
            } catch {
                quickFailures += 1
                if quickFailures >= 3 { return .failed(error.localizedDescription) }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            defer { listener.stop() }
            let began = ContinuousClock.now
            do {
                for try await transcript in stream {
                    if let command = VoiceCommand.lastCommand(in: transcript) {
                        lastHeard = command.title
                        return .heard(command)
                    }
                }
                quickFailures = 0
            } catch {
                if began.duration(to: .now) < .seconds(1) {
                    quickFailures += 1
                    if quickFailures >= 5 { return .failed("Speech recognition keeps failing: \(error.localizedDescription)") }
                    try? await Task.sleep(for: .milliseconds(500))
                } else {
                    quickFailures = 0
                }
            }
        }
        return nil
    }

    // MARK: - Voices

    /// A side of the card to read.
    private struct Reading: Sendable {
        let side: CardSide
        let card: VoiceCard
        /// Whether its script and recordings are made now, if they aren't
        /// there: a card added since the AI voice started.
        let records: Bool
    }

    /// Reads a side in the AI voice when it's been recorded, or when it can
    /// be within a few seconds; in the iPhone's voice otherwise, from the
    /// script when there is one. A recording that comes too late is still
    /// kept, for next time.
    private func read(_ reading: Reading) async {
        guard let aiVoice else {
            await speaker.speak(reading.side == .question ? reading.card.question : reading.card.answer)
            return
        }
        let file = await recorder.recording(
            of: reading.side,
            for: reading.card,
            voice: aiVoice,
            rewrites: aiRewrites,
            make: reading.records,
            waitingAtMost: .seconds(8)
        )
        if reading.records { voiceProblem = recorder.problem }
        guard !Task.isCancelled else { return }
        if let file {
            if await speaker.play(file) { return }
            CardVoiceRecordings.discard(file)
            guard !Task.isCancelled else { return }
        }
        await speaker.speak(recorder.text(of: reading.side, for: reading.card, rewrites: aiRewrites))
    }

    /// Whether a card's script and recordings are made: it's one of the
    /// cards chosen, added after `aiVoiceSince` (a card's id is the moment
    /// it was added, in milliseconds), and its question has words to read.
    private func recordsInAIVoice(_ cardId: CardID?, _ card: VoiceCard) -> Bool {
        guard let aiVoiceSince, let cardId, !card.written.question.isEmpty else { return false }
        return Double(cardId.rawValue) / 1000 >= aiVoiceSince.timeIntervalSince1970
    }

    /// Starts the next card's script and recordings while this one is
    /// read, so there's no wait for them.
    private func prepareUpcomingCard(_ session: ReviewSession) {
        guard let aiVoice, let next = session.upcomingCard else { return }
        let card = VoiceCard(front: next.frontHTML, back: next.backHTML, deckName: session.deckName)
        guard recordsInAIVoice(next.id, card) else { return }
        recorder.prepare(card, voice: aiVoice, rewrites: aiRewrites)
    }

    // MARK: - Answers

    private func rate(_ rating: Rating, _ session: ReviewSession) async {
        guard !session.isAdvancing else { return }
        session.answer(rating: rating)
        await settle(session)
    }

    private func undo(_ session: ReviewSession) async {
        guard session.canUndo, !session.isAdvancing else {
            await speaker.speak("Nothing to undo.")
            return
        }
        session.undo()
        await settle(session)
    }

    /// Until the answer or undo has gone through and the next card is up.
    private func settle(_ session: ReviewSession) async {
        var waited = 0
        while session.isAdvancing, waited < 100, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    /// Lets the card's own sound play first; it starts a moment after the
    /// card appears.
    private func waitForCardAudio(_ session: ReviewSession) async {
        try? await Task.sleep(for: .milliseconds(300))
        var waited = 0
        while session.isAudioPlaying, waited < 60, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
    }

    private func show(_ phase: Phase) {
        guard loop != nil, !Task.isCancelled else { return }
        self.phase = phase
    }

    private func end(problem: String?) {
        self.problem = problem
        stop()
    }
}

/// Where the session stands, to notice a tap that moves it on.
private struct SessionMark: Equatable, Sendable {
    let cardId: CardID?
    let showAnswer: Bool
    let isFinished: Bool

    @MainActor
    init(_ session: ReviewSession) {
        cardId = session.currentCardId
        showAnswer = session.showAnswer
        isFinished = session.isFinished
    }
}
#endif
