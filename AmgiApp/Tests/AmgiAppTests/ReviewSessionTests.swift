//
//  ReviewSessionTests.swift
//  AmgiAppTests
//
//  Created by Vladimir Gusev on 01.05.2026.
//

import Testing
import SwiftUI
import UIKit
import Dependencies
import Foundation
import AnkiKit
import AnkiServices
@testable import AmgiApp
@testable import ReviewCore

// MARK: - ReviewSessionTests
// Lifted from ~/Clones/amgi/AnkiApp/Sources/Review/ReviewSessionTests.swift (82 LOC)
// Adapted to our architecture: @MainActor class, async revealAnswer(), swift-dependencies mocking.
//
// Migrated from XCTest -> Swift Testing. Per-test setUp/tearDown is replaced
// by per-instance `init` — Swift Testing creates a fresh `ReviewSessionTests`
// instance for every `@Test` method, so `session` is reinitialised cleanly.

@MainActor
@Suite struct ReviewSessionTests {
    let session: ReviewSession

    init() {
        session = ReviewSession(deckId: DeckID(1))
    }

    /// Polls `condition` instead of racing a fixed sleep against
    /// `ReviewSession.start()`'s off-main-actor async chain — avoids
    /// flaking when that chain takes longer than a hardcoded delay.
    private func pollUntil(
        timeout: Duration = .milliseconds(2000),
        interval: Duration = .milliseconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: interval)
        }
    }

    // MARK: - Deferred from fork

    // DEFERRED: fork's testCurrentCardInitiallyNil / testCurrentCardPublicAccess /
    // testCurrentCardStructure test `session.currentCard` — a public property in the
    // fork's ReviewSession. Our ReviewSession exposes `currentCardOrdinal: UInt32`
    // but keeps `currentQueuedCard` private. Exposing it would require a public accessor
    // that PR 1a did not add. Use `currentCardOrdinal == 0` as a proxy.
    // PR 1a defer: add `public private(set) var currentCard: QueuedReviewCard?` when needed.

    // MARK: - Property Exposure Tests

    /// currentCardOrdinal should be 0 before the session starts (maps to fork's currentCard == nil).
    @Test func currentCardOrdinalInitiallyZero() {
        #expect(session.currentCardOrdinal == 0,
                "currentCardOrdinal should be 0 before session starts")
    }

    // MARK: - Initial State Tests

    /// Session stats should all be zero-initialised (mirrors fork's testSessionStatsInitialized).
    @Test func sessionStatsInitialized() {
        #expect(session.sessionStats.reviewed == 0, "Initial reviewed count should be 0")
        #expect(session.sessionStats.correct == 0, "Initial correct count should be 0")
        #expect(session.sessionStats.totalTimeMs == 0, "Initial time should be 0")
    }

    /// Remaining counts should be zero before start() (mirrors fork's testRemainingCountsInitialized).
    @Test func remainingCountsInitialized() {
        #expect(session.remainingCounts.newCount == 0)
        #expect(session.remainingCounts.learnCount == 0)
        #expect(session.remainingCounts.reviewCount == 0)
    }

    /// nextIntervals should be empty before any card is loaded (mirrors fork's testNextIntervalsStructure).
    @Test func nextIntervalsStructure() {
        #expect(session.nextIntervals.isEmpty,
                "nextIntervals should be empty initially")
    }

    /// isFinished should be false before start() (mirrors fork's testIsFinishedInitiallyFalse).
    @Test func isFinishedInitiallyFalse() {
        #expect(!session.isFinished, "Session should not be finished initially")
    }

    @Test func onlyARoundCountsCardsLeftInIt() {
        #expect(session.cardsLeftInRound == nil, "an ordinary session isn't a round")
    }

    /// showAnswer should be false before any card is loaded (mirrors fork's testShowAnswerInitiallyFalse).
    @Test func showAnswerInitiallyFalse() {
        #expect(!session.showAnswer, "Answer should not be visible initially")
    }

    // MARK: - Additional initial-state checks (not in fork; added to fill gaps)

    @Test func canUndoInitiallyFalse() {
        #expect(!session.canUndo,
                "canUndo should be false before any card is answered")
    }

    @Test func frontHTMLInitiallyEmpty() {
        #expect(session.frontHTML.isEmpty,
                "frontHTML should be empty before session starts")
    }

    @Test func backHTMLInitiallyEmpty() {
        #expect(session.backHTML.isEmpty,
                "backHTML should be empty before session starts")
    }

    @Test func cardCSSInitiallyEmpty() {
        #expect(session.cardCSS.isEmpty,
                "cardCSS should be empty before session starts")
    }

    @Test func requiresTypedAnswerInputInitiallyFalse() {
        #expect(!session.requiresTypedAnswerInput,
                "requiresTypedAnswerInput should be false initially")
    }

    // MARK: - start() with empty queue

    /// When the scheduler returns an empty queue, start() should mark the session finished.
    /// start() now runs its backend chain off the main actor in an internal Task, so the
    /// assertion waits for that work to settle.
    @Test func startWithEmptyQueueFinishesSession() async throws {
        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                QueuedCardsResult(cards: [], newCount: 0, learningCount: 0, reviewCount: 0)
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(42))
            s.start()
            try await pollUntil { s.isFinished && !s.isAdvancing }
            #expect(s.isFinished,
                    "Session with empty queue should be finished after start()")
            #expect(s.remainingCounts == .zero)
            #expect(!s.isAdvancing, "isAdvancing should clear once start() settles")
        }
    }

    // MARK: - revealAnswer() sets showAnswer

    /// revealAnswer() when there is no typed-answer placeholder should set showAnswer = true.
    /// Tests the async path without needing a running card queue.
    @Test func revealAnswerSetsShowAnswer() async {
        // No typedAnswerState is set (no cards loaded), so revealAnswer() takes
        // the non-typed branch and immediately sets showAnswer = true.
        #expect(!session.showAnswer)
        await session.revealAnswer()
        #expect(session.showAnswer,
                "showAnswer should be true after revealAnswer() with no typed-answer state")
    }

    // MARK: - Audio / Chrome state (Task 2)

    @Test func updateAudioPlayingFlipsObservableFlag() {
        let session = ReviewSession(deckId: DeckID(1))
        #expect(!session.isAudioPlaying)
        session.updateAudioPlaying(true)
        #expect(session.isAudioPlaying)
        session.updateAudioPlaying(false)
        #expect(!session.isAudioPlaying)
    }

    @Test func updateCardChromeStoresColorAndDarkness() {
        let session = ReviewSession(deckId: DeckID(1))
        #expect(session.cardChromeColor == .clear)
        #expect(!session.cardChromeIsDark)
        session.updateCardChrome(color: .red, isDark: false)
        #expect(session.cardChromeColor == .red)
        #expect(!session.cardChromeIsDark)
        session.updateCardChrome(color: .black, isDark: true)
        #expect(session.cardChromeColor == .black)
        #expect(session.cardChromeIsDark)
    }

    // MARK: - Replay / Stop-audio bump mutators (Task 3)

    @Test func bumpReplayRequestIncrementsCounter() {
        let session = ReviewSession(deckId: DeckID(1))
        #expect(session.replayRequestID == 0)
        session.bumpReplayRequest()
        #expect(session.replayRequestID == 1)
        session.bumpReplayRequest()
        #expect(session.replayRequestID == 2)
    }

    @Test func bumpStopAudioRequestIncrementsCounter() {
        let session = ReviewSession(deckId: DeckID(1))
        #expect(session.stopAudioRequestID == 0)
        session.bumpStopAudioRequest()
        #expect(session.stopAudioRequestID == 1)
    }

    // MARK: - currentNote cache + TemplateTarget (Task 4)

    @Test func currentNoteCachedOnAdvance() async throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let callCounter = Counter()
        let stubNote = NoteRecord(
            id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0,
            flds: "", sfld: "", csum: 0
        )
        let stubCard = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let stubResult = QueuedCardsResult(
            cards: [stubCard], newCount: 1, learningCount: 0, reviewCount: 0
        )

        try await withDependencies {
            $0.notesService.getNote = { noteId in
                callCounter.value += 1
                #expect(noteId == NoteID(100))
                return stubNote
            }
            $0.schedulerService.getQueuedCards = { _ in stubResult }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "<p>front</p>", backHTML: "<p>back</p>", cardCSS: "")
            }
            $0.decksService.setCurrentDeck = { _ in }
            $0.decksService.getCurrentDeck = { DeckInfo(id: DeckID(1), name: "Deck") }
        } operation: {
            let session = ReviewSession(deckId: DeckID(1))
            session.start()
            try await pollUntil { session.currentNote != nil }
            #expect(session.currentNote == stubNote)
            #expect(callCounter.value == 1, "getNote should be called exactly once per advance")

            // Re-observe currentNote — must not trigger additional fetches
            _ = session.currentNote
            _ = session.currentNote
            #expect(callCounter.value == 1, "currentNote is cached, not refetched on observation")
        }
    }

    @Test func currentTemplateTargetDerivedFromCachedNoteAndCard() async throws {
        let stubNote = NoteRecord(
            id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0,
            flds: "", sfld: "", csum: 0
        )
        let stubCard = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 3)
        let stubResult = QueuedCardsResult(
            cards: [stubCard], newCount: 1, learningCount: 0, reviewCount: 0
        )

        try await withDependencies {
            $0.notesService.getNote = { _ in stubNote }
            $0.schedulerService.getQueuedCards = { _ in stubResult }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
            $0.decksService.setCurrentDeck = { _ in }
        } operation: {
            let session = ReviewSession(deckId: DeckID(1))
            session.start()
            try await pollUntil { !session.isAdvancing }
            let target = session.currentTemplateTarget
            #expect(target != nil)
            #expect(target?.notetypeId == NotetypeID(200))
            #expect(target?.ordinal == 3)
        }
    }

    // MARK: - Full audio/chrome round-trip (Task 11)

    @Test func fullAudioAndChromeRoundTrip() async throws {
        let stubCard = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let stubResult = QueuedCardsResult(
            cards: [stubCard], newCount: 1, learningCount: 0, reviewCount: 0
        )
        let stubNote = NoteRecord(id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)

        try await withDependencies {
            $0.notesService.getNote = { _ in stubNote }
            $0.schedulerService.getQueuedCards = { _ in stubResult }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
            $0.decksService.setCurrentDeck = { _ in }
        } operation: {
            let session = ReviewSession(deckId: DeckID(1))
            session.start()
            try await pollUntil { !session.isAdvancing }

            // Audio start
            session.updateAudioPlaying(true)
            #expect(session.isAudioPlaying)

            // Capture baseline: advance() already bumped stopAudioRequestID once on card load
            let stopBaselineID = session.stopAudioRequestID

            // User taps replay-while-playing → stop bump (toolbar logic, here exercised manually)
            session.bumpStopAudioRequest()
            #expect(session.stopAudioRequestID == stopBaselineID + 1)

            // JS replies to amgiStopAllAudio → onAudioStateChange(false)
            session.updateAudioPlaying(false)
            #expect(!session.isAudioPlaying)

            // User taps replay again → replay bump
            session.bumpReplayRequest()
            #expect(session.replayRequestID == 1)

            // JS reports a card-bg color
            session.updateCardChrome(color: .blue, isDark: false)
            #expect(session.cardChromeColor == .blue)
        }
    }

    // MARK: - refreshAfterEdit() (Task 5)

    @Test func refreshAfterEditRerendersCurrentCardWithoutAdvancing() async throws {
        final class State: @unchecked Sendable {
            var renderCallCount = 0
            var noteFields = "old front\u{1f}old back"
        }
        let state = State()
        let stubCard = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let stubResult = QueuedCardsResult(
            cards: [stubCard], newCount: 1, learningCount: 0, reviewCount: 0
        )

        try await withDependencies {
            $0.notesService.getNote = { _ in
                NoteRecord(id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0, flds: state.noteFields, sfld: "", csum: 0)
            }
            $0.schedulerService.getQueuedCards = { _ in stubResult }
            $0.cardRenderingService.renderCard = { _ in
                state.renderCallCount += 1
                return RenderedCard(
                    frontHTML: "<p>render-\(state.renderCallCount)</p>",
                    backHTML: "<p>back-\(state.renderCallCount)</p>",
                    cardCSS: ""
                )
            }
            $0.decksService.setCurrentDeck = { _ in }
        } operation: {
            let session = ReviewSession(deckId: DeckID(1))
            session.start()
            try await pollUntil { !session.isAdvancing }

            let originalNoteId = session.currentNote?.id
            #expect(state.renderCallCount == 1)
            #expect(session.frontHTML.contains("render-1"))

            // Simulate field edit
            state.noteFields = "new front\u{1f}new back"
            await session.refreshAfterEdit()

            #expect(session.currentNote?.id == originalNoteId, "queue does not advance")
            #expect(state.renderCallCount == 2, "renderCard called again on refresh")
            #expect(session.frontHTML.contains("render-2"), "frontHTML reflects re-render")
        }
    }

    // MARK: - Off-main advance (start/answer run their backend chain off the main actor)

    /// answer() answers the current card, re-fetches the queue, and advances to
    /// the next card — all off the main actor — then updates stats on main.
    @Test func answerAdvancesToNextCardAndUpdatesStats() async throws {
        let card1 = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let card2 = QueuedReviewCard.preview(cardId: CardID(2), noteId: NoteID(101), ord: 0)
        let note1 = NoteRecord(id: NoteID(100), guid: "g1", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
        let note2 = NoteRecord(id: NoteID(101), guid: "g2", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)

        final class Box: @unchecked Sendable { var answered = false }
        let box = Box()

        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                // start() sees both cards; after answerReviewCard fires, only card2 remains.
                box.answered
                    ? QueuedCardsResult(cards: [card2], newCount: 1, learningCount: 0, reviewCount: 0)
                    : QueuedCardsResult(cards: [card1, card2], newCount: 2, learningCount: 0, reviewCount: 0)
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in box.answered = true }
            $0.notesService.getNote = { id in id == NoteID(100) ? note1 : note2 }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            try await pollUntil { !s.isAdvancing }
            #expect(s.currentNote == note1)

            s.answer(rating: .good)
            // answer() holds the card until the rating toast's 450ms minimum
            // display elapses, so the settle wait must outlast it.
            try await Task.sleep(for: .milliseconds(700))

            #expect(s.sessionStats.reviewed == 1)
            #expect(s.sessionStats.correct == 1, "Good counts as correct")
            #expect(s.pace.answerCount == 1, "the answer sets the pace for the time left")
            #expect(s.canUndo)
            #expect(s.currentNote == note2, "should advance to the second card")
            #expect(!s.isAdvancing, "isAdvancing clears once the answer settles")
        }
    }

    /// isAdvancing flips true synchronously inside start() (before the internal
    /// Task runs) and clears once the off-main transition settles.
    @Test func isAdvancingSetSynchronouslyThenClears() async throws {
        let card = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                QueuedCardsResult(cards: [card], newCount: 1, learningCount: 0, reviewCount: 0)
            }
            $0.notesService.getNote = { _ in
                NoteRecord(id: NoteID(100), guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
            }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            #expect(s.isAdvancing, "start() sets isAdvancing synchronously before its Task runs")
            try await pollUntil { !s.isAdvancing }
            #expect(!s.isAdvancing, "isAdvancing clears after the transition settles")
            #expect(!s.isFinished, "a non-empty queue should not finish")
        }
    }

    // MARK: - start() failure

    /// A failed start used to set `isFinished`, landing the user on the
    /// congratulations surface — green checkmark, "You've reviewed 0 cards",
    /// success haptic — for a backend error. The two states are now distinct.
    @Test func startFailureReportsAnErrorInsteadOfFinishing() async throws {
        struct StartFailure: Error {}

        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in throw StartFailure() }
            $0.schedulerService.getQueuedCards = { _ in
                QueuedCardsResult(cards: [], newCount: 0, learningCount: 0, reviewCount: 0)
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            try await pollUntil { !s.isAdvancing }

            #expect(s.startError != nil, "a failed start must surface the failure")
            #expect(!s.isFinished,
                    "isFinished drives the congratulations surface and its success haptic; a failure is not a finished deck")
        }
    }

    // MARK: - Prefetch

    /// The card *after* the current one is rendered while the user reads, so
    /// the engine render is off the tap-to-next-card path.
    @Test func rendersTheFollowingCardBeforeTheUserAnswers() async throws {
        let card1 = QueuedReviewCard.preview(cardId: CardID(1), noteId: NoteID(100), ord: 0)
        let card2 = QueuedReviewCard.preview(cardId: CardID(2), noteId: NoteID(101), ord: 0)

        // renderCard is called from two concurrent detached tasks (the current
        // card's prepare and the prefetch), so the recorder locks.
        final class Rendered: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [CardID] = []
            func record(_ id: CardID) { lock.lock(); ids.append(id); lock.unlock() }
            var all: [CardID] { lock.lock(); defer { lock.unlock() }; return ids }
        }
        let rendered = Rendered()

        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                QueuedCardsResult(cards: [card1, card2], newCount: 2, learningCount: 0, reviewCount: 0)
            }
            $0.notesService.getNote = { id in
                NoteRecord(id: id, guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
            }
            $0.cardRenderingService.renderCard = { id in
                rendered.record(id)
                return RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.start()
            try await pollUntil { rendered.all.contains(CardID(2)) }

            #expect(rendered.all.contains(CardID(1)), "the current card is rendered")
            #expect(rendered.all.contains(CardID(2)),
                    "the following card should be prefetched during the user's reading time")
            #expect(!s.isAdvancing, "prefetch must not hold the transition gate shut")
        }
    }

    // MARK: - Card order: every due card before repeats

    private static func card(_ id: Int64, queue: Int16) -> QueuedReviewCard {
        QueuedReviewCard.preview(cardId: CardID(id), noteId: NoteID(100 + id), ord: 0, queue: queue)
    }

    /// The engine's order is learning cards due now, the main queue, then
    /// learning cards inside the learn-ahead window.
    @Test func repeatsWaitUntilEveryOtherDueCardHasBeenShown() {
        let engineOrder = [
            Self.card(1, queue: 1),  // relearning, due now
            Self.card(2, queue: 4),  // preview repeat
            Self.card(3, queue: 2),  // review
            Self.card(4, queue: 0),  // new
            Self.card(5, queue: 3),  // interday learning
            Self.card(6, queue: 1),  // learning, due within learn-ahead
        ]
        let arranged = ReviewQueueOrder.arranged(engineOrder, defersRepeats: true)
        #expect(arranged.map(\.card.id.rawValue) == [3, 4, 5, 1, 2, 6])
    }

    @Test func repeatsAreShownOnceNothingElseIsDue() {
        let engineOrder = [Self.card(1, queue: 1), Self.card(2, queue: 1)]
        let arranged = ReviewQueueOrder.arranged(engineOrder, defersRepeats: true)
        #expect(arranged.map(\.card.id.rawValue) == [1, 2])
    }

    @Test func switchedOffKeepsTheEngineOrder() {
        let engineOrder = [Self.card(1, queue: 1), Self.card(2, queue: 2)]
        let arranged = ReviewQueueOrder.arranged(engineOrder, defersRepeats: false)
        #expect(arranged.map(\.card.id.rawValue) == [1, 2])
    }

    /// Card 1 was missed earlier and is due again; card 2 hasn't been seen.
    @Test(arguments: [true, false])
    func startOpensOnAnUnseenCardBeforeARepeat(defersRepeats: Bool) async throws {
        let missed = Self.card(1, queue: 1)
        let unseen = Self.card(2, queue: 2)
        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                QueuedCardsResult(cards: [missed, unseen], newCount: 0, learningCount: 1, reviewCount: 1)
            }
            $0.notesService.getNote = { id in
                NoteRecord(id: id, guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
            }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.defersRepeats = defersRepeats
            s.start()
            try await pollUntil { s.currentCardId != nil && !s.isAdvancing }
            #expect(s.currentCardId == (defersRepeats ? unseen : missed).card.id)
        }
    }

    /// Missing card 2 sends it back into learning behind card 1; card 3,
    /// not yet seen, still comes next.
    @Test func answerMovesOnToAnUnseenCardBeforeAnyRepeat() async throws {
        let missedEarlier = Self.card(1, queue: 1)
        let current = Self.card(2, queue: 2)
        let missedNow = Self.card(2, queue: 1)
        let unseen = Self.card(3, queue: 2)

        final class Box: @unchecked Sendable { var answered = false }
        let box = Box()

        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                box.answered
                    ? QueuedCardsResult(cards: [missedEarlier, missedNow, unseen], newCount: 0, learningCount: 2, reviewCount: 1)
                    : QueuedCardsResult(cards: [missedEarlier, current, unseen], newCount: 0, learningCount: 1, reviewCount: 2)
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in box.answered = true }
            $0.notesService.getNote = { id in
                NoteRecord(id: id, guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
            }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.defersRepeats = true
            s.start()
            try await pollUntil { s.currentCardId == current.card.id && !s.isAdvancing }
            #expect(s.currentCardId == current.card.id)

            s.answer(rating: .again)
            try await pollUntil { s.currentCardId == unseen.card.id && !s.isAdvancing }
            #expect(s.currentCardId == unseen.card.id)
            #expect(s.sessionStats.reviewed == 1)
        }
    }

    @Test func aCardAlreadySeenIsLeftOutAltogether() {
        let engineOrder = [Self.card(1, queue: 1), Self.card(2, queue: 2), Self.card(3, queue: 1)]
        let arranged = ReviewQueueOrder.arranged(engineOrder, defersRepeats: false, skipping: [CardID(1)])
        #expect(arranged.map(\.card.id.rawValue) == [2, 3])
    }

    // MARK: - Each card once (the Library's rounds)

    /// Card 1 is missed and comes due again straight away; in a round that
    /// shows each card once it isn't shown again, the count stays at the
    /// day's total, and the round ends after card 2. Undo makes card 2
    /// unseen again.
    @Test func aRoundShowsEachCardOnceAgainstAFixedTotal() async throws {
        let first = Self.card(1, queue: 2)
        let second = Self.card(2, queue: 2)
        let firstMissed = Self.card(1, queue: 1)

        final class Engine: @unchecked Sendable {
            private let lock = NSLock()
            private var answered = 0
            var answeredCount: Int { lock.lock(); defer { lock.unlock() }; return answered }
            func step(_ delta: Int) { lock.lock(); answered += delta; lock.unlock() }
        }
        let engine = Engine()

        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                switch engine.answeredCount {
                case 0:
                    QueuedCardsResult(cards: [first, second], newCount: 0, learningCount: 0, reviewCount: 2)
                case 1:
                    // The missed card is due again at once, ahead of card 2.
                    QueuedCardsResult(cards: [firstMissed, second], newCount: 0, learningCount: 1, reviewCount: 1)
                default:
                    QueuedCardsResult(cards: [firstMissed], newCount: 0, learningCount: 1, reviewCount: 0)
                }
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in engine.step(1) }
            $0.collectionService.undoLast = { engine.step(-1) }
            $0.notesService.getNote = { id in
                NoteRecord(id: id, guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
            }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.defersRepeats = false
            s.showsEachCardOnce = true
            s.cardsDoneBefore = 10
            #expect(s.cardsLeftInRound == nil, "not loaded yet")
            s.start()
            try await pollUntil { s.currentCardId == first.card.id && !s.isAdvancing }
            #expect(s.sessionTotal == 12, "10 done earlier today and 2 in the deck")
            #expect(s.cardPosition == 11)
            #expect(s.cardsLeftInRound == 2)

            s.answer(rating: .again)
            try await pollUntil { s.currentCardId == second.card.id && !s.isAdvancing }
            #expect(s.currentCardId == second.card.id, "the missed card waits for another round")
            #expect(s.sessionTotal == 12, "the total doesn't grow when the missed card comes due")
            #expect(s.cardPosition == 12)
            #expect(s.cardsLeftInRound == 1)

            s.answer(rating: .good)
            try await pollUntil { s.isFinished && !s.isAdvancing }
            #expect(s.isFinished, "every card has had its turn, though the missed one is due")
            #expect(s.progressFraction == 1)
            #expect(s.cardsLeftInRound == 0)

            s.undo()
            try await pollUntil { s.currentCardId == second.card.id && !s.isAdvancing }
            #expect(!s.isFinished)
            #expect(s.cardPosition == 12)
            #expect(s.cardsLeftInRound == 1)
        }
    }

    // MARK: - A gap above the Extra field

    @Test func theExtraFieldIsMarkedWhereItBegins() {
        let back = #"The <span class="cloze">heart</span> pumps blood<br>"# + "\nFour chambers"
        let marked = ExtraFieldMarker.marking(
            back,
            fieldNames: ["Text", "Back Extra"],
            fieldValues: ["The {{c1::heart}} pumps blood", "Four chambers"]
        )
        #expect(marked == #"The <span class="cloze">heart</span> pumps blood<br>"# + "\n" + ExtraFieldMarker.html + "Four chambers")
    }

    @Test func anExtraInATagOrAScriptIsPassedOverForTheOneOnThePage() {
        let back = #"<div data-x="Note"></div><script>var e = "Note";</script>Text<br><div id="extra">Note</div>"#
        let marked = ExtraFieldMarker.marking(back, fieldNames: ["Text", "Extra"], fieldValues: ["Text", "Note"])
        #expect(marked == #"<div data-x="Note"></div><script>var e = "Note";</script>Text<br><div id="extra">"# + ExtraFieldMarker.html + #"Note</div>"#)
    }

    @Test func withoutAnExtraOnThePageNothingIsMarked() {
        let back = "Front<hr id=answer>Back"
        #expect(ExtraFieldMarker.marking(back, fieldNames: ["Front", "Back"], fieldValues: ["Front", "Back"]) == back, "no Extra field")
        #expect(ExtraFieldMarker.marking(back, fieldNames: ["Text", "Extra"], fieldValues: ["Front", ""]) == back, "an empty Extra")
        #expect(ExtraFieldMarker.marking(back, fieldNames: ["Text", "Extra"], fieldValues: ["Front", "Not shown"]) == back, "not on the page")
    }

    // MARK: - Problem cards

    private static func reviewCard(lapses: Int32, flags: Int32 = 0, type: Int16 = 2) -> CardRecord {
        CardRecord(id: CardID(1), nid: NoteID(1), did: DeckID(1), mod: 0, type: type, queue: 2, lapses: lapses, flags: flags)
    }

    @Test func aCardForgottenOftenEnoughBecomesAProblemCard() {
        #expect(ProblemCardRule.isProblem(after: .again, on: Self.reviewCard(lapses: 4), threshold: 5))
        #expect(ProblemCardRule.isProblem(after: .again, on: Self.reviewCard(lapses: 9), threshold: 5), "still a problem past it")
        #expect(!ProblemCardRule.isProblem(after: .again, on: Self.reviewCard(lapses: 3), threshold: 5), "one short")
        #expect(!ProblemCardRule.isProblem(after: .good, on: Self.reviewCard(lapses: 9), threshold: 5), "remembered")
        #expect(!ProblemCardRule.isProblem(after: .again, on: Self.reviewCard(lapses: 9, type: 3), threshold: 5), "relearning adds no lapse")
        #expect(!ProblemCardRule.isProblem(after: .again, on: Self.reviewCard(lapses: 9, flags: 1), threshold: 5), "already flagged")
        #expect(!ProblemCardRule.isProblem(after: .again, on: Self.reviewCard(lapses: 9), threshold: 0), "switched off")
        #expect(ProblemCardRule.existingSearch(threshold: 5) == "prop:lapses>=5 flag:0 -deck:p")
    }

    /// A miss that reaches the threshold flags the card orange when the
    /// session closes, not mid-session; an undone miss flags nothing.
    @Test func problemCardsAreFlaggedAsTheSessionCloses() async throws {
        let shaky = QueuedReviewCard.preview(
            cardId: CardID(1), noteId: NoteID(101), ord: 0, queue: 2, type: 2, lapses: 4
        )
        let other = Self.card(2, queue: 2)

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var answered = 0
            private var flags: [String] = []
            var answeredCount: Int { lock.lock(); defer { lock.unlock() }; return answered }
            func step(_ delta: Int) { lock.lock(); answered += delta; lock.unlock() }
            func flag(_ entry: String) { lock.lock(); flags.append(entry); lock.unlock() }
            var flagged: [String] { lock.lock(); defer { lock.unlock() }; return flags }
        }
        let log = Recorder()

        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                log.answeredCount == 0
                    ? QueuedCardsResult(cards: [shaky, other], newCount: 0, learningCount: 0, reviewCount: 2)
                    : QueuedCardsResult(cards: [other], newCount: 0, learningCount: 0, reviewCount: 1)
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in log.step(1) }
            $0.collectionService.undoLast = { log.step(-1) }
            $0.cardClient.flag = { id, flag in log.flag("\(id.rawValue):\(flag)") }
            $0.notesService.getNote = { id in
                NoteRecord(id: id, guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
            }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.problemCardLapses = 5
            s.start()
            try await pollUntil { s.currentCardId == CardID(1) && !s.isAdvancing }

            s.answer(rating: .again)
            try await pollUntil { s.currentCardId == other.card.id && !s.isAdvancing }
            #expect(log.flagged.isEmpty, "nothing flagged mid-session")

            s.undo()
            try await pollUntil { s.currentCardId == CardID(1) && !s.isAdvancing }
            #expect(await s.flagProblemCards() == 0, "the undone miss doesn't count")

            s.answer(rating: .again)
            try await pollUntil { s.currentCardId == other.card.id && !s.isAdvancing }
            #expect(await s.flagProblemCards() == 1)
            #expect(log.flagged == ["1:2"], "flagged orange")
        }
    }

    // MARK: - Hands-free

    @Test func theLastCommandWordSaidCounts() {
        #expect(VoiceCommand.lastCommand(in: "show") == .reveal)
        #expect(VoiceCommand.lastCommand(in: "Hmm… good") == .rate(.good))
        #expect(VoiceCommand.lastCommand(in: "again, no wait, easy!") == .rate(.easy), "later words win")
        #expect(VoiceCommand.lastCommand(in: "Repeat that") == .repeatSide)
        #expect(VoiceCommand.lastCommand(in: "undo") == .undo)
        #expect(VoiceCommand.lastCommand(in: "OK stop") == .stop)
        #expect(VoiceCommand.lastCommand(in: "what was that") == nil)
        #expect(VoiceCommand.lastCommand(in: "goodness") == nil, "only whole words")
        #expect(VoiceCommand.lastCommand(in: "bury") == .bury)
        #expect(VoiceCommand.lastCommand(in: "berry") == .bury, "as it's often heard")
        #expect(VoiceCommand.lastCommand(in: "red flag") == .flag(1))
        #expect(VoiceCommand.lastCommand(in: "Flag red") == .flag(1))
        #expect(VoiceCommand.lastCommand(in: "orange flag") == .flag(2))
        #expect(VoiceCommand.lastCommand(in: "flag orange") == .flag(2))
        #expect(VoiceCommand.lastCommand(in: "flag") == .flag(1), "red, as in Anki")
        #expect(VoiceCommand.lastCommand(in: "the red one") == nil, "a colour alone is nothing")
        #expect(VoiceCommand.lastCommand(in: "heart") == .rate(.hard), "as hard is often heard")
    }

    @Test func aCommandTheReadingSaysCountsOnlyWhenSaidAgain() {
        let echo = VoiceCommand.counts(in: "A good sign: red flag, then good again.")
        #expect(echo[.rate(.good)] == 2)
        #expect(echo[.rate(.again)] == 1)
        #expect(echo[.flag(1)] != nil)
        #expect(VoiceCommand.lastCommand(in: "good", beyond: echo) == nil, "the reading's own word")
        #expect(VoiceCommand.lastCommand(in: "good sign red flag then good again", beyond: echo) == nil, "all of it heard back")
        #expect(VoiceCommand.lastCommand(in: "good good good", beyond: echo) == .rate(.good), "said once more than read")
        #expect(VoiceCommand.lastCommand(in: "good easy", beyond: echo) == .rate(.easy), "not in the reading")
        #expect(VoiceCommand.lastCommand(in: "easy then good", beyond: echo) == .rate(.easy), "the echo doesn't win")
        #expect(VoiceCommand.lastCommand(in: "good", beyond: [:]) == .rate(.good), "nothing being read")
    }

    @Test func theAnswerIsReadWithoutTheQuestionAboveIt() {
        let back = #"<style>.card{}</style><div class="card">Ptosis, miosis, anhidrosis?<hr id=answer>Horner syndrome<br>Sympathetic lesion</div>"#
        #expect(SpokenCardText.answer(fromHTML: back) == "Horner syndrome. Sympathetic lesion.")
        #expect(SpokenCardText.answer(fromHTML: "<b>Whole</b> back") == "Whole back.", "no divider: all of it")
    }

    @Test func aClozeAnswerIsJustTheRevealedClozeWithoutTheExtra() {
        let back = #"The <span class="cloze" data-ordinal="1"><b>heart</b></span> pumps <span class="cloze-inactive">blood</span>.<br>"#
            + ExtraFieldMarker.html + "Four chambers"
        #expect(SpokenCardText.answer(fromHTML: back) == "heart.")
        let basic = #"Q?<hr id=answer>Horner syndrome<br>"# + ExtraFieldMarker.html + "Extra notes"
        #expect(SpokenCardText.answer(fromHTML: basic) == "Horner syndrome.", "the Extra is never read")
    }

    @Test func whatTheCardDoesntShowIsntRead() {
        // `##"`: the hint link's `href="#"` would end a `#"` string.
        let front = ##"<div class="card"><span class="cloze">[...]</span> is the drug of choice<br><a class=hint href="#" onclick="this.style.display='none';return false;">Lecture Notes</a><div id="hint1" class=hint style="display: none">Hidden <div>nested</div> stuff</div></div>"##
        #expect(SpokenCardText.question(fromHTML: front) == "blank is the drug of choice.")
        let math = #"<div>\(x^2\) &amp; <img src="a.png"> [sound:a.mp3] <svg><path d="M0"/></svg>done</div>"#
        #expect(SpokenCardText.readable(math) == "x^2 & done.")
        #expect(SpokenCardText.readable(#"<img src="x.png">"#).isEmpty)
    }

    @Test func eachWritingSystemGetsItsOwnVoice() {
        #expect(SpokenCardText.segments("안녕하세요. Hello there.") == [
            .init(text: "안녕하세요.", script: .hangul),
            .init(text: "Hello there.", script: .other),
        ])
        #expect(SpokenCardText.segments("日本語 (にほんご) means Japanese") == [
            .init(text: "日本語 (にほんご)", script: .japanese),
            .init(text: "means Japanese", script: .other),
        ])
        #expect(SpokenCardText.segments("中文") == [.init(text: "中文", script: .chinese)])
        #expect(SpokenCardText.segments("1, 2, 3") == [.init(text: "1, 2, 3", script: .other)])
        #expect(SpokenCardText.segments("  ").isEmpty)
    }

    @Test func shorthandIsReadTheWayAPersonSaysIt() {
        #expect(SpokenCardText.spoken("↑ HR → ↓ CO") == "increased HR leads to decreased CO")
        #expect(SpokenCardText.spoken("Give 5 mg/kg q6h") == "Give 5 milligrams per kilogram every 6 hours")
        #expect(SpokenCardText.spoken("BP 120/80 mmHg") == "BP 120 over 80 millimeters of mercury")
        #expect(SpokenCardText.spoken("HCO3- 22-28 mEq/L") == "bicarbonate 22 to 28 milliequivalents per liter", "an ion, not a range")
        #expect(SpokenCardText.spoken("Ca²⁺ 8.5–10.5 mg/dL") == "calcium 8.5 to 10.5 milligrams per deciliter")
        #expect(SpokenCardText.spoken("WBC 4.5×10⁹/L") == "WBC 4.5 times 10 to the 9 per liter")
        #expect(SpokenCardText.spoken("45 yo pt w/ 3 wk h/o cough") == "45 year old patient with 3 weeks history of cough")
        #expect(SpokenCardText.spoken("Tx: amoxicillin 500 mg tid x 10 d") == "treatment: amoxicillin 500 milligrams three times a day for 10 days")
        #expect(SpokenCardText.spoken("K+ < 3.5, ANA (+)") == "potassium less than 3.5, ANA positive")
        #expect(SpokenCardText.spoken("1 mg") == "1 milligram")
    }

    @Test func whatIsntShorthandIsReadAsWritten() {
        for text in ["Type IV hypersensitivity", "COVID-19 and IL-6", "20/20 vision", "2 hours later", "Factor V Leiden", "x^2 & done."] {
            #expect(SpokenCardText.spoken(text) == text)
        }
    }

    @Test func aCardSideIsReadInFull() {
        #expect(SpokenCardText.question(fromHTML: "<div>↑ PTH &rarr; ↑ Ca<sup>2+</sup></div>") == "increased PTH leads to increased calcium.")
        #expect(SpokenCardText.readable("5 &#8594; 6 &micro;g, 10<sup>9</sup>") == "5 → 6 \u{00B5}g, 10^9.")
    }

    @Test func theAIVoiceGetsTheCardAsWrittenToRewrite() {
        let front = #"<span class="cloze" data-ordinal="1">[...]</span> is the drug of choice for absence seizures"#
        #expect(SpokenCardText.questionAsWritten(fromHTML: front) == "[...] is the drug of choice for absence seizures.",
                "the blank stays a blank")
        #expect(SpokenCardText.answerAsWritten(fromHTML: "Q?<hr id=answer>↑ PTH") == "↑ PTH.", "shorthand left for it to say")
        #expect(SpokenCardText.answer(fromHTML: "Q?<hr id=answer>↑ PTH") == "increased PTH.")
    }

    // MARK: - New cards learned in a filtered deck

    /// The engine credits an answer to the filtered deck the card sits in,
    /// so the session tallies new cards by home deck and charges them when
    /// it closes. An undone answer comes back off the tally.
    @Test func newCardsLearnedInAFilteredDeckAreChargedToTheirHomeDecksOnClose() async throws {
        let fromKorean = QueuedReviewCard.preview(
            cardId: CardID(1), noteId: NoteID(101), ord: 0, queue: 0, originalDeckId: DeckID(5)
        )
        let fromNeuro = QueuedReviewCard.preview(
            cardId: CardID(2), noteId: NoteID(102), ord: 0, queue: 0, originalDeckId: DeckID(6)
        )

        final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            private var answered = 0
            private var charged: [String] = []
            var answeredCount: Int { lock.lock(); defer { lock.unlock() }; return answered }
            func step(_ delta: Int) { lock.lock(); answered += delta; lock.unlock() }
            func charge(_ entry: String) { lock.lock(); charged.append(entry); lock.unlock() }
            var chargedEntries: [String] { lock.lock(); defer { lock.unlock() }; return charged }
        }
        let progress = Progress()

        try await withDependencies {
            $0.decksService.setCurrentDeck = { _ in }
            $0.schedulerService.getQueuedCards = { _ in
                let remaining = Array([fromKorean, fromNeuro].dropFirst(progress.answeredCount))
                return QueuedCardsResult(cards: remaining, newCount: remaining.count, learningCount: 0, reviewCount: 0)
            }
            $0.schedulerService.answerReviewCard = { _, _, _, _ in progress.step(1) }
            $0.schedulerService.recordNewCardsStudied = { deck, count in
                progress.charge("\(deck.rawValue):\(count)")
            }
            $0.collectionService.undoLast = { progress.step(-1) }
            $0.notesService.getNote = { id in
                NoteRecord(id: id, guid: "g", mid: NotetypeID(200), mod: 0, flds: "", sfld: "", csum: 0)
            }
            $0.cardRenderingService.renderCard = { _ in
                RenderedCard(frontHTML: "f", backHTML: "b", cardCSS: "")
            }
        } operation: {
            let s = ReviewSession(deckId: DeckID(1))
            s.countsNewCardsAgainstHomeDecks = true
            s.start()
            try await pollUntil { s.currentCardId == fromKorean.card.id && !s.isAdvancing }

            s.answer(rating: .good)
            try await pollUntil { s.currentCardId == fromNeuro.card.id && !s.isAdvancing }
            s.answer(rating: .good)
            try await pollUntil { s.isFinished && !s.isAdvancing }

            // Take the second answer back: only the first card stays charged.
            #expect(s.pace.answerCount == 2)
            s.undo()
            try await pollUntil { s.currentCardId == fromNeuro.card.id && !s.isAdvancing }
            #expect(s.pace.answerCount == 1, "an undone answer no longer counts toward the pace")

            await s.recordNewCardsStudied()
            #expect(progress.chargedEntries == ["5:1"])

            // Recording again charges nothing twice.
            await s.recordNewCardsStudied()
            #expect(progress.chargedEntries == ["5:1"])
        }
    }

    // MARK: - Time left

    private static func pace(answersOf seconds: [Double], missing misses: Int = 0) -> ReviewPace {
        var pace = ReviewPace()
        for (index, answer) in seconds.enumerated() {
            pace.record(milliseconds: Int(answer * 1000), missed: index < misses)
        }
        return pace
    }

    @Test func noEstimateUntilAFewCardsHaveSetAPace() {
        let counts = DeckCounts(newCount: 0, learnCount: 0, reviewCount: 10)
        #expect(Self.pace(answersOf: [10, 10]).secondsLeft(for: counts) == nil)
        #expect(Self.pace(answersOf: [10, 10, 10]).secondsLeft(for: counts) != nil)
    }

    /// Three 10-second answers and no misses yet: the miss rate leans on
    /// one in ten, (0 + 0.5) / (3 + 5), so ten cards take ten answers and
    /// the repeats those misses bring back.
    @Test func theEstimateIsCardsLeftAtThisSessionsPace() throws {
        let pace = Self.pace(answersOf: [8, 10, 12])
        let left = try #require(pace.secondsLeft(for: DeckCounts(newCount: 0, learnCount: 0, reviewCount: 10)))
        #expect(abs(left - 10 / (1 - 0.0625) * 10) < 0.001)
    }

    @Test func aNewCardCountsTwiceForItsLearningStep() throws {
        let pace = Self.pace(answersOf: [10, 10, 10])
        let reviews = try #require(pace.secondsLeft(for: DeckCounts(newCount: 0, learnCount: 0, reviewCount: 6)))
        let newCards = try #require(pace.secondsLeft(for: DeckCounts(newCount: 3, learnCount: 0, reviewCount: 0)))
        #expect(abs(reviews - newCards) < 0.001)
    }

    @Test func moreMissesMeanMoreTimeLeft() throws {
        let counts = DeckCounts(newCount: 0, learnCount: 2, reviewCount: 8)
        let steady = try #require(Self.pace(answersOf: [10, 10, 10, 10]).secondsLeft(for: counts))
        let shaky = try #require(Self.pace(answersOf: [10, 10, 10, 10], missing: 2).secondsLeft(for: counts))
        #expect(shaky > steady)
    }

    @Test func aCardLeftOpenCountsAsAMinuteAtMost() throws {
        let counts = DeckCounts(newCount: 0, learnCount: 0, reviewCount: 1)
        let away = try #require(Self.pace(answersOf: [600, 600, 600]).secondsLeft(for: counts))
        let slow = try #require(Self.pace(answersOf: [60, 60, 60]).secondsLeft(for: counts))
        #expect(away == slow)
    }

    @Test func aRoundKnowsExactlyHowManyAnswersAreLeft() throws {
        let pace = Self.pace(answersOf: [8, 10, 12])
        let left = try #require(pace.secondsLeft(forAnswers: 30))
        #expect(abs(left - 300) < 0.001, "30 cards at 10 seconds each, no repeats to allow for")
        #expect(Self.pace(answersOf: [10, 10]).secondsLeft(forAnswers: 30) == nil)
    }

    @Test func anUndoneAnswerNoLongerCounts() {
        var pace = Self.pace(answersOf: [10, 10, 10])
        pace.removeLast()
        #expect(pace.answerCount == 2)
        #expect(pace.secondsLeft(for: DeckCounts(newCount: 0, learnCount: 0, reviewCount: 5)) == nil)
    }

    @Test func theTimeLeftReadsAsMinutesAndAFinishTime() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ReviewPace.summary(secondsLeft: nil, now: now) == "Measuring your pace…")
        #expect(ReviewPace.summary(secondsLeft: 20, now: now) == "Less than a minute left")
        let summary = ReviewPace.summary(secondsLeft: 125 * 60, now: now)
        #expect(summary.hasPrefix("About 2 h 5 min left · done around "))
        #expect(ReviewPace.duration(minutes: 12) == "12 min")
        #expect(ReviewPace.duration(minutes: 60) == "1 h")
        #expect(ReviewPace.duration(minutes: 61) == "1 h 1 min")
    }
}
