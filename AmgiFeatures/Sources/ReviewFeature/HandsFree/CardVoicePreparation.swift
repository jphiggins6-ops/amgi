//
//  CardVoicePreparation.swift
//  ReviewFeature
//

#if canImport(UIKit)
import Foundation
public import Observation
import UIKit
import AnkiKit
import AppCore
import MnemonicCore
import ReviewCore

/// Settings → Review → AI Voice → Prepare Cards Now: the AI voice's script
/// and recordings for every card hands-free mode would read in it, made
/// ahead, so no card waits for them. Cards already done are skipped, so it
/// can stop and carry on another time. One card at a time: when Google
/// asks for a pause it waits out the minute, and when the key's daily
/// limit is reached it stops until tomorrow.
@MainActor
@Observable
public final class CardVoicePreparation {
    public static let shared = CardVoicePreparation()

    public enum Phase: Equatable, Sendable {
        case idle
        /// Rendering the cards to find the ones still to do.
        case checking
        /// Found them; waiting for a yes.
        case confirming(toDo: Int, ready: Int)
        case preparing(done: Int, of: Int)
        /// How it went, shown until it's started again.
        case finished(String)
    }

    public private(set) var phase: Phase = .idle
    /// Stop was tapped; the card under way is finished first.
    public private(set) var isStopping = false

    /// Roughly what a card costs: its rewrite and two recordings.
    public static let costPerCard = 0.002

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var toDo: [VoiceCard] = []
    @ObservationIgnored private var madeRecorder: AIVoiceRecorder?

    private var recorder: AIVoiceRecorder {
        if let madeRecorder { return madeRecorder }
        let made = AIVoiceRecorder()
        madeRecorder = made
        return made
    }

    private init() {}

    public var isWorking: Bool {
        switch phase {
        case .checking, .preparing: true
        case .idle, .confirming, .finished: false
        }
    }

    /// The cards to do, and how; nil when the AI voice is off.
    private struct Plan {
        let voice: String
        let rewrites: Bool
        /// Cards added before this are left to the iPhone voice.
        let since: Date

        static var current: Plan? {
            let cards = ReviewPreferences.aiVoiceCards
            guard cards != .off else { return nil }
            return Plan(
                voice: ReviewPreferences.aiVoice.rawValue,
                rewrites: ReviewPreferences.aiVoiceRewrites,
                since: cards == .all ? .distantPast : ReviewPreferences.aiVoiceSince
            )
        }

        /// A card's id is the moment it was added, in milliseconds.
        func includes(_ cardId: CardID) -> Bool {
            Double(cardId.rawValue) / 1000 >= since.timeIntervalSince1970
        }
    }

    /// Finds the cards still to do, then waits for `start()`.
    public func check() {
        guard !isWorking else { return }
        guard let plan = Plan.current else {
            phase = .finished("Choose which cards the AI voice reads first.")
            return
        }
        guard recorder.hasKey else {
            phase = .finished(CardVoiceError.noKey.localizedDescription)
            return
        }
        phase = .checking
        work = Task {
            let sides = CardVoiceSides()
            do {
                var found: [VoiceCard] = []
                var ready = 0
                for cardId in try await sides.cardIds() where plan.includes(cardId) {
                    guard !Task.isCancelled else { return }
                    guard let html = await sides.sides(of: cardId) else { continue }
                    let card = VoiceCard(front: html.front, back: html.back, deckName: "")
                    guard !card.written.question.isEmpty else { continue }
                    if recorder.isReady(card, voice: plan.voice, rewrites: plan.rewrites) {
                        ready += 1
                    } else {
                        found.append(card)
                    }
                }
                toDo = found
                phase = found.isEmpty
                    ? .finished("All \(ready) cards are ready.")
                    : .confirming(toDo: found.count, ready: ready)
            } catch {
                phase = .finished("The cards couldn't be listed: \(error.localizedDescription)")
            }
        }
    }

    /// Makes the cards `check()` found ready.
    public func start() {
        guard !isWorking, !toDo.isEmpty, let plan = Plan.current else { return }
        let cards = toDo
        toDo = []
        isStopping = false
        phase = .preparing(done: 0, of: cards.count)
        // A locked phone would pause the work.
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task {
            let ending = await prepare(cards, plan: plan)
            UIApplication.shared.isIdleTimerDisabled = false
            isStopping = false
            phase = .finished(ending)
        }
    }

    /// Leaves the cards found for another time.
    public func cancel() {
        guard !isWorking else { return }
        toDo = []
        phase = .idle
    }

    /// Stops after the card under way.
    public func stop() {
        switch phase {
        case .checking:
            work?.cancel()
            phase = .idle
        case .preparing:
            isStopping = true
            work?.cancel()
        case .idle, .confirming, .finished:
            break
        }
    }

    /// One card at a time, so Google's limits are met one request at a
    /// time; says how it went.
    private func prepare(_ cards: [VoiceCard], plan: Plan) async -> String {
        var done = 0
        var failed = 0
        var failuresInARow = 0
        for card in cards {
            if Task.isCancelled {
                return "Stopped with \(done) of \(cards.count) cards ready. Cards already done are skipped next time."
            }
            var made = await recorder.make(card, voice: plan.voice, rewrites: plan.rewrites)
            // Google asked for a pause: wait out the minute, then try again.
            var waits = 0
            while !made, waits < 5, let pause = AIVoiceRecorder.pause, !pause.daily, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(1, pause.until.timeIntervalSinceNow)))
                made = await recorder.make(card, voice: plan.voice, rewrites: plan.rewrites)
                waits += 1
            }
            if made {
                done += 1
                failuresInARow = 0
            } else {
                failed += 1
                failuresInARow += 1
            }
            phase = .preparing(done: done, of: cards.count)

            if AIVoiceRecorder.isPaused, AIVoiceRecorder.pause?.daily == true {
                return "\(done) cards were made ready, then the Gemini voice reached Google’s daily limit for this key (about 100 recordings on most accounts, roughly 50 cards). Tap Prepare Cards Now again tomorrow to carry on: \(cards.count - done) cards to go, and the ones done are skipped."
            }
            if failuresInARow >= 3 {
                return "Stopped with \(done) of \(cards.count) cards ready, after three cards in a row couldn’t be done. \(recorder.problem ?? "")"
            }
        }
        if failed > 0 {
            return "Done: \(done) cards are ready; \(failed) couldn’t be done and will be tried again next time. \(recorder.problem ?? "")"
        }
        return "Done: \(done) cards are ready."
    }
}
#endif
