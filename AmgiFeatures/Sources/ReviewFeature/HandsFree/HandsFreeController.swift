//
//  HandsFreeController.swift
//  ReviewFeature
//

#if canImport(UIKit)
import Foundation
import Observation
import AnkiKit
import AppCore
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
/// Cards added since the AI voice started (`ReviewPreferences.aiVoiceSince`)
/// are read in it: each side is recorded by OpenAI the first time it's
/// read, the next card's while this one is, and kept on the phone
/// (`CardVoiceRecordings`), so it's paid for once. The deck that was there
/// before is read in the iPhone's best voice, for free, as is anything
/// whose recording doesn't come in time.
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
    /// Cards added from this moment on are recorded in the AI voice; nil
    /// when it's off or there's no OpenAI key.
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
        aiVoice = ReviewPreferences.aiVoiceForNewCards ? ReviewPreferences.aiVoice.rawValue : nil
        aiVoiceSince = aiVoice != nil && recorder.hasKey ? ReviewPreferences.aiVoiceSince : nil
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

            let recordsCard = recordsInAIVoice(session.currentCardId)
            if !session.showAnswer {
                show(.readingQuestion)
                let question = Self.speakable(SpokenCardText.question(fromHTML: session.frontHTML))
                if recordsCard, let aiVoice {
                    // Ready by the time the card turns over.
                    recorder.prepare(Self.speakable(SpokenCardText.answer(fromHTML: session.backHTML)), voice: aiVoice)
                }
                prepareUpcomingCard(session)
                switch await speakThenListen(question, recording: recordsCard, then: .waitingToShow, session: session, listenAfter: true) {
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
                let answer = Self.speakable(SpokenCardText.answer(fromHTML: session.backHTML))
                prepareUpcomingCard(session)
                switch await speakThenListen(answer, recording: recordsCard, then: .waitingForRating, session: session, listenAfter: true) {
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
    /// it early either way. `recording`: see `read(_:recording:)`.
    ///
    /// The reading, the listening and the watch for taps race as plain
    /// tasks, and the first to finish wins (`Race`). A task group is the
    /// textbook way to write that, but Swift 6.2's region-based isolation
    /// checker rejects main-actor child tasks in one ("Pattern that the
    /// region-based isolation checker does not understand how to check").
    private func speakThenListen(
        _ text: String,
        recording: Bool,
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
            await self.read(text, recording: recording)
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

    /// Reads `text` in the AI voice when it's been recorded, or when it can
    /// be within a few seconds (`recording`: a card added since the AI
    /// voice started); in the iPhone's voice otherwise. A recording that
    /// comes too late is still kept, for next time.
    private func read(_ text: String, recording: Bool) async {
        if let aiVoice {
            let file = await recorder.recording(of: text, voice: aiVoice, make: recording, waitingAtMost: .seconds(6))
            if recording { voiceProblem = recorder.problem }
            guard !Task.isCancelled else { return }
            if let file {
                if await speaker.play(file) { return }
                CardVoiceRecordings.discard(file)
                guard !Task.isCancelled else { return }
            }
        }
        await speaker.speak(text)
    }

    /// Whether a card's sides are recorded in the AI voice: it was added
    /// since the AI voice started. A card's id is the moment it was added,
    /// in milliseconds.
    private func recordsInAIVoice(_ cardId: CardID?) -> Bool {
        guard let aiVoiceSince, let cardId else { return false }
        return Double(cardId.rawValue) / 1000 >= aiVoiceSince.timeIntervalSince1970
    }

    /// Starts recording the next card while this one is read, so there's
    /// no wait for it.
    private func prepareUpcomingCard(_ session: ReviewSession) {
        guard let aiVoice, let next = session.upcomingCard, recordsInAIVoice(next.id) else { return }
        recorder.prepare(Self.speakable(SpokenCardText.question(fromHTML: next.frontHTML)), voice: aiVoice)
        recorder.prepare(Self.speakable(SpokenCardText.answer(fromHTML: next.backHTML)), voice: aiVoice)
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

    private static func speakable(_ text: String) -> String {
        text.isEmpty ? "Nothing to read on this side." : text
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
