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
/// The question is read; "show" reads the answer, or a rating said straight
/// away reads the answer and then goes on with it. On the answer side,
/// "again", "hard", "good" or "easy" rates it and the next card starts.
/// "Repeat" reads the side again, "undo" takes the last answer back, and
/// "stop" ends hands-free. Taps on the screen still work, and the reading
/// follows them. It carries on with the screen locked (the app's background
/// audio mode).
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

    var isOn: Bool { phase != .off }

    /// Made on first use: the review screen is rebuilt often, and most
    /// sessions never turn hands-free on.
    @ObservationIgnored private var voice: (speaker: CardSpeaker, listener: VoiceListener)?
    @ObservationIgnored private var loop: Task<Void, Never>?

    private var speaker: CardSpeaker { audio.speaker }
    private var listener: VoiceListener { audio.listener }

    private var audio: (speaker: CardSpeaker, listener: VoiceListener) {
        if let voice { return voice }
        let made = (speaker: CardSpeaker(), listener: VoiceListener())
        voice = made
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

        // A rating said on the question side, applied once the answer has
        // been read.
        var pendingRating: Rating?

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

            if !session.showAnswer {
                pendingRating = nil
                show(.readingQuestion)
                let question = Self.speakable(SpokenCardText.question(fromHTML: session.frontHTML))
                switch await speakThenListen(question, then: .waitingToShow, session: session, listenAfter: true) {
                case .heard(.reveal):
                    session.revealAnswer()
                case .heard(.rate(let rating)):
                    pendingRating = rating
                    session.revealAnswer()
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
                let rated = pendingRating
                pendingRating = nil
                switch await speakThenListen(answer, then: .waitingForRating, session: session, listenAfter: rated == nil) {
                case .spoke:
                    if let rated { await rate(rated, session) }
                case .heard(.rate(let rating)):
                    await rate(rating, session)
                case .heard(.undo):
                    await undo(session)
                case .heard(.stop):
                    end(problem: nil)
                    return
                case .heard(.reveal), .heard(.repeatSide):
                    // Read the answer again; a rating said earlier still stands.
                    pendingRating = rated
                    continue
                case .failed(let message):
                    end(problem: message)
                    return
                case .changed, .cancelled:
                    continue
                }
            }
        }
    }

    /// Reads `text`, listening for a command: during the reading with
    /// headphones on, after it otherwise. With `listenAfter` off, reading
    /// to the end is itself the outcome. A tap that changes the card ends
    /// it early either way.
    private func speakThenListen(
        _ text: String,
        then waiting: Phase,
        session: ReviewSession,
        listenAfter: Bool
    ) async -> Outcome {
        let mark = SessionMark(session)
        let bargeIn = HandsFreeAudioSession.canListenWhileSpeaking
        return await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { @MainActor in
                await self.speaker.speak(text)
                if Task.isCancelled { return nil }
                if !listenAfter { return .spoke }
                self.show(waiting)
                if bargeIn { return nil }
                return await self.hear()
            }
            if bargeIn {
                group.addTask { @MainActor in
                    await self.hear()
                }
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    if SessionMark(session) != mark { return .changed }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return nil
            }
            var outcome = Outcome.cancelled
            for await result in group {
                if let result {
                    outcome = result
                    break
                }
            }
            group.cancelAll()
            return outcome
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
