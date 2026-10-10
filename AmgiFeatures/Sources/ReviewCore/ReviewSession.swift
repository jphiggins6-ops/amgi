//
//  ReviewSession.swift
//  ReviewCore
//
//  Created by Vladimir Gusev on 27.03.2026.
//

import OSLog
public import SwiftUI
import AppCore
#if canImport(UIKit)
import UIKit
#endif
public import AmgiCardWeb
import AnkiClients
public import AnkiKit
import AnkiServices
import Dependencies
import Foundation

public enum ResolvedRenderMode: Equatable, Sendable {
    case native(front: NativeCardContent, back: NativeCardContent)
    case html
}

@Observable @MainActor
public final class ReviewSession {
    public let deckId: DeckID

    @ObservationIgnored @Dependency(\.decksService) var decks
    @ObservationIgnored @Dependency(\.schedulerService) var scheduler
    @ObservationIgnored @Dependency(\.cardRenderingService) var cardRendering
    @ObservationIgnored @Dependency(\.collectionService) var collection
    @ObservationIgnored @Dependency(\.notesService) var notes
    @ObservationIgnored @Dependency(\.notetypesService) var notetypes
    @ObservationIgnored @Dependency(\.notetypesClient) var notetypesClient
    @ObservationIgnored @Dependency(\.cardClient) var cardClient

    public private(set) var frontHTML: String = ""
    public private(set) var backHTML: String = ""
    public private(set) var cardCSS: String = ""
    public private(set) var showAnswer: Bool = false
    public private(set) var sessionStats: SessionStats = .init()
    public private(set) var remainingCounts: DeckCounts = .zero
    /// How quickly this session's cards are being answered; see
    /// `estimatedSecondsLeft`.
    public private(set) var pace = ReviewPace()
    public private(set) var deckName: String = ""
    public private(set) var isFinished: Bool = false
    public private(set) var canUndo: Bool = false
    public private(set) var nextIntervals: [Rating: String] = [:]
    public private(set) var replayRequestID: Int = 0       // plumbed; consumer is PR 1b
    public private(set) var stopAudioRequestID: Int = 0    // plumbed; consumer is PR 1b
    public private(set) var isAudioPlaying: Bool = false
    public private(set) var currentNote: NoteRecord?
    public private(set) var cardChromeColor: Color = .clear
    public private(set) var cardChromeIsDark: Bool = false
    public private(set) var resolvedMode: ResolvedRenderMode = .html
    public private(set) var resolvedByAuto: Bool = false
    public private(set) var templateName: String?
    public private(set) var answerTapCount: Int = 0
    public private(set) var tappedRating: Rating = .good
    public private(set) var undoneCount: Int = 0

    public private(set) var isAdvancing: Bool = false
    public var answerError: String?
    public private(set) var startError: String?

    var reviewStartTime: ContinuousClock.Instant = .now
    /// When the card last changed or turned over; see `acceptsGestures`.
    @ObservationIgnored private var lastFlip: ContinuousClock.Instant = .now
    var cardQueue: [QueuedReviewCard] = []
    /// Read once per session; see `ReviewQueueOrder`.
    @ObservationIgnored var defersRepeats: Bool = ReviewPreferences.defersRepeats
    /// When set, new cards learned here out of a filtered deck are tallied
    /// by home deck, and `recordNewCardsStudied()` charges them to those
    /// decks' daily new-card limits. The engine credits an answer to the
    /// deck the card sits in, so without this a filtered deck of new cards
    /// never uses up any limit and today's new cards never run out.
    @ObservationIgnored public var countsNewCardsAgainstHomeDecks = false
    @ObservationIgnored private var newCardsStudied: [DeckID: Int32] = [:]
    /// Shows each card once. A card answered in this session isn't shown
    /// again however soon it falls due, and the session ends once every
    /// card in its deck has had a turn. Progress then counts cards rather
    /// than answers, against `cardsDoneBefore` plus the deck as it opened,
    /// so the total stays put when a missed card comes due again. For the
    /// Library's study buttons, whose decks hold today's cards. Set before
    /// `start()`.
    @ObservationIgnored public var showsEachCardOnce = false
    /// With `showsEachCardOnce`: how many of the day's cards were done
    /// before this session, so its progress reads against the whole day.
    @ObservationIgnored public var cardsDoneBefore = 0
    /// With `showsEachCardOnce`: the cards answered so far, which the queue
    /// skips.
    @ObservationIgnored private var seenThisSession: Set<CardID> = []
    /// The card the last answer went to, so an undo can make it unseen.
    @ObservationIgnored private var lastAnsweredCard: CardID?
    /// How many cards the engine counted in the deck as the session began.
    private var cardsAtStart = 0
    /// Lapses that make a card a problem card (`ProblemCardRule`); 0 is
    /// off. Read once per session.
    @ObservationIgnored public var problemCardLapses = ReviewPreferences.problemCardLapses
    /// Problem cards found this session, flagged for the Graveyard as it
    /// closes (`flagProblemCards()`). Flagging at once would put a flag
    /// change between the answer and Undo.
    @ObservationIgnored private var problemCards: Set<CardID> = []
    /// The problem card the last answer found, so an undo can drop it.
    @ObservationIgnored private var lastProblemCard: CardID?
    /// The home deck the last answer was tallied under, so an undo can take
    /// it back off.
    @ObservationIgnored private var lastTalliedHomeDeck: DeckID?
    var notetypeCache: [NotetypeID: Notetype] = [:]
    var currentQueuedCard: QueuedReviewCard?
    private var lastRating: Rating? = nil
    private var preparedNext: (id: CardID, card: PreparedCard)?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    var renderedFrontHTML: String = ""
    var renderedBackHTML: String = ""
    var typedAnswerState: TypedAnswerState?
    public var typedAnswer: String = ""

    // MARK: - Computed

    public var isTypedAnswerCard: Bool {
        typedAnswerState?.expected.isEmpty == false
    }

    public var requiresTypedAnswerInput: Bool {
        isTypedAnswerCard && !showAnswer
    }

    public var currentCardOrdinal: UInt32 {
        UInt32(max(0, currentQueuedCard?.card.ord ?? 0))
    }

    public struct TemplateTarget: Identifiable, Equatable, Sendable {
        public let notetypeId: NotetypeID
        public let ordinal: Int

        public var id: String { "\(notetypeId.rawValue)-\(ordinal)" }
    }

    public var currentTemplateTarget: TemplateTarget? {
        guard let card = currentQueuedCard?.card, let note = currentNote else { return nil }
        return TemplateTarget(notetypeId: note.mid, ordinal: Int(card.ord))
    }

    public var currentCardId: CardID? {
        currentQueuedCard?.card.id
    }

    /// The card after this one, as its sides will show, once it has been
    /// rendered ahead (`prefetchFollowingCard`): a guess, like that is. For
    /// hands-free mode to get the card's voice ready while this one is read.
    public var upcomingCard: (id: CardID, frontHTML: String, backHTML: String)? {
        preparedNext.map { (id: $0.id, frontHTML: $0.card.frontHTML, backHTML: $0.card.renderedBackHTML) }
    }

    // MARK: - Session progress

    /// With `showsEachCardOnce`, the day's cards: those done before this
    /// session plus the deck as it opened. Otherwise the answers given plus
    /// the engine's count of what's left, which grows as cards come back.
    public var sessionTotal: Int {
        showsEachCardOnce
            ? cardsDoneBefore + cardsAtStart
            : sessionStats.reviewed + remainingCounts.total
    }

    /// In a session that shows each card once, every answer is a different
    /// card, so answers given count cards done.
    private var cardsDone: Int {
        (showsEachCardOnce ? cardsDoneBefore : 0) + sessionStats.reviewed
    }

    public var cardPosition: Int {
        min(cardsDone + 1, max(sessionTotal, 1))
    }

    public var progressFraction: Double {
        sessionTotal > 0 ? Double(cardsDone) / Double(sessionTotal) : 0
    }

    /// With `showsEachCardOnce`: the round's cards not answered yet, or nil
    /// until the deck has loaded. What the Today widget and the app icon
    /// count when the app is left mid-round.
    public var cardsLeftInRound: Int? {
        guard showsEachCardOnce else { return nil }
        if isFinished { return 0 }
        guard cardsAtStart > 0 else { return nil }
        return max(0, cardsAtStart - sessionStats.reviewed)
    }

    /// Roughly how long the cards still to come will take at this session's
    /// pace, or nil until a few answers have set one. See `ReviewPace`.
    public var estimatedSecondsLeft: Double? {
        guard !isFinished else { return nil }
        guard showsEachCardOnce else { return pace.secondsLeft(for: remainingCounts) }
        return pace.secondsLeft(forAnswers: cardsAtStart - sessionStats.reviewed)
    }

    /// Enough to reach every unseen card: seen cards sit in the engine's
    /// list as learning cards, possibly ahead of them.
    private var queueFetchLimit: Int32 {
        Int32(clamping: 200 + seenThisSession.count + 1)
    }

    /// False while a card is changing and for a moment after it turns
    /// over, so the second tap of a quick double tap on the card can't
    /// rate the answer the first tap revealed.
    public var acceptsGestures: Bool {
        !isAdvancing && lastFlip.duration(to: .now) > .milliseconds(350)
    }

    var currentFlag: UInt32 {
        UInt32(max(0, currentQueuedCard?.card.flags ?? 0)) & 0b111
    }

    @ObservationIgnored public private(set) lazy var mediaFolder: URL? = {
        @Dependency(\.mediaClient) var mediaClient
        return mediaClient.folderURL()
    }()

    // MARK: - Init

    public init(deckId: DeckID) {
        self.deckId = deckId
    }

    // MARK: - Public interface

    public func start() {
        guard !isAdvancing else { return }
        isAdvancing = true
        startError = nil
        // Resolve the Sendable service facades here, in the caller's
        // dependency scope, then hand them to the off-actor work.
        let decks = self.decks
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let deckId = self.deckId
        let fetchLimit = queueFetchLimit
        Task {
            defer { isAdvancing = false }
            do {
                let (queue, name) = try await Task.detached { () -> (QueuedCardsResult, String) in
                    try decks.setCurrentDeck(deckId)
                    let name = (try? decks.getCurrentDeck().name) ?? ""
                    return (try scheduler.getQueuedCards(fetchLimit), name)
                }.value
                cardQueue = ReviewQueueOrder.arranged(queue.cards, defersRepeats: defersRepeats, skipping: seenThisSession)
                cardsAtStart = queue.newCount + queue.learningCount + queue.reviewCount
                deckName = name
                remainingCounts = DeckCounts(
                    newCount: queue.newCount,
                    learnCount: queue.learningCount,
                    reviewCount: queue.reviewCount
                )
                Log.review.info("Started with \(self.cardQueue.count) cards, counts: new=\(queue.newCount) learn=\(queue.learningCount) review=\(queue.reviewCount)")
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering)
            } catch {
                // NOT isFinished: that is the "queue ran dry" state and drives
                // the congratulations surface plus a success haptic. A start
                // failure gets its own state and a retry.
                Log.review.error("Start failed: \(error)")
                startError = error.localizedDescription
            }
        }
    }

    /// Flips to the answer side immediately. For typed-answer cards the diff
    /// is computed off the main actor and substituted when it lands — the
    /// `compareAnswer` FFI call used to run inline here, blocking the main
    /// thread at the exact moment of the tap.
    public func revealAnswer() {
        guard !showAnswer else { return }
        backHTML = strippingTypedAnswerPlaceholders(from: renderedBackHTML)
        showAnswer = true
        lastFlip = .now

        guard let state = typedAnswerState else { return }
        let typed = typedAnswer
        let rendered = renderedBackHTML
        let cardRendering = self.cardRendering
        let cardId = currentCardId
        Task {
            let html = await Task.detached {
                typedAnswerBackHTML(
                    state: state,
                    typedAnswer: typed,
                    renderedBackHTML: rendered,
                    cardRendering: cardRendering
                )
            }.value
            // The card can advance while the diff is in flight; don't paste a
            // stale answer over the new card.
            guard cardId == currentCardId, showAnswer else { return }
            backHTML = html
        }
    }

    public func answer(rating: Rating) {
        guard !isAdvancing, let queued = currentQueuedCard else { return }
        isAdvancing = true

        // ContinuousClock, not Date: a backwards wall-clock adjustment
        // (NTP correction, manual change) mid-review made this negative,
        // and UInt32(negative) traps. Clamped as well, since a card left
        // open for ~49.7 days would overflow.
        let elapsed = reviewStartTime.duration(to: .now)
        let elapsedMs = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        let timeSpent = UInt32(min(max(elapsedMs, 0), Int64(UInt32.max)))
        let cardId = queued.card.id
        let states = queued.states
        // Queue 0 is Anki's new queue; a non-zero original deck means the
        // card is in a filtered deck.
        let isProblem = ProblemCardRule.isProblem(after: rating, on: queued.card, threshold: problemCardLapses)
        let homeDeckToTally: DeckID? = countsNewCardsAgainstHomeDecks
            && queued.card.queue == 0
            && queued.card.odid.rawValue != 0
            ? queued.card.odid
            : nil
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let fetchLimit = queueFetchLimit

        answerTapCount += 1
        tappedRating = rating

        // The interval brackets the whole tap-to-next-card wait, not the
        // synchronous prologue above: the scheduler round-trip and the
        // advance are what the user actually waits on.
        Task {
            defer { isAdvancing = false }
            await AppSignpost.measure("AnswerCard") {
                do {
                    let queue = try await Task.detached {
                        try scheduler.answerReviewCard(cardId, rating, timeSpent, states)
                        return try scheduler.getQueuedCards(fetchLimit)
                    }.value

                    answerError = nil
                    sessionStats.reviewed += 1
                    if rating != .again { sessionStats.correct += 1 }
                    sessionStats.totalTimeMs += Int(timeSpent)
                    pace.record(milliseconds: Int(timeSpent), missed: rating == .again)
                    lastRating = rating
                    canUndo = true
                    if let homeDeckToTally {
                        newCardsStudied[homeDeckToTally, default: 0] += 1
                    }
                    lastTalliedHomeDeck = homeDeckToTally
                    lastAnsweredCard = cardId
                    if showsEachCardOnce { seenThisSession.insert(cardId) }
                    lastProblemCard = isProblem ? cardId : nil
                    if isProblem { problemCards.insert(cardId) }

                    cardQueue = ReviewQueueOrder.arranged(queue.cards, defersRepeats: defersRepeats, skipping: seenThisSession)
                    remainingCounts = DeckCounts(
                        newCount: queue.newCount,
                        learnCount: queue.learningCount,
                        reviewCount: queue.reviewCount
                    )
                    await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering)
                } catch {
                    // Do NOT drop the card. Silently removing it from the queue
                    // and advancing meant the review was never recorded, the
                    // card was skipped for the session, remainingCounts drifted
                    // permanently from the backend's, and the user saw an
                    // entirely normal advance.
                    Log.review.error("Answer failed: \(error)")
                    answerError = error.localizedDescription
                }
            }
        }
    }

    /// Buries the card on screen until tomorrow and moves on, as Anki's
    /// Bury does from the reviewer. Undo takes it back.
    public func buryCurrentCard() {
        guard !isAdvancing, let queued = currentQueuedCard else { return }
        isAdvancing = true
        let cardId = queued.card.id
        let cardClient = self.cardClient
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let fetchLimit = queueFetchLimit

        Task {
            defer { isAdvancing = false }
            do {
                try await cardClient.bury(cardId)
                let queue = try await Task.detached {
                    try scheduler.getQueuedCards(fetchLimit)
                }.value
                // Undo now takes back the bury, which isn't an answer.
                canUndo = true
                lastRating = nil
                lastTalliedHomeDeck = nil
                lastAnsweredCard = nil
                lastProblemCard = nil
                cardQueue = ReviewQueueOrder.arranged(queue.cards, defersRepeats: defersRepeats, skipping: seenThisSession)
                remainingCounts = DeckCounts(
                    newCount: queue.newCount,
                    learnCount: queue.learningCount,
                    reviewCount: queue.reviewCount
                )
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering)
            } catch {
                Log.review.error("Bury failed: \(error)")
                answerError = error.localizedDescription
            }
        }
    }

    /// The card on screen moved to another deck (into 1_critical, say, or
    /// out of the filtered deck it was studied from). Its scheduling states
    /// are worked out again under its new deck's settings, as the engine
    /// refuses an answer made with the ones it was queued with, and the
    /// answer buttons' intervals change to match. The card stays on screen,
    /// to be answered as usual.
    public func cardMovedDeck() async {
        guard let queued = currentQueuedCard else { return }
        let cardId = queued.card.id
        let scheduler = self.scheduler
        let cardClient = self.cardClient
        do {
            let fresh = try await Task.detached {
                try scheduler.getSchedulingStates(cardId)
            }.value
            let card = try await cardClient.fetch(cardId)
            guard currentQueuedCard?.card.id == cardId else { return }
            let updated = queued.updated(card: card, scheduling: fresh)
            currentQueuedCard = updated
            nextIntervals = updated.nextIntervals
            if let index = cardQueue.firstIndex(where: { $0.card.id == cardId }) {
                cardQueue[index] = updated
            }
            answerError = nil
        } catch {
            Log.review.error("A moved card's scheduling couldn't be refreshed: \(error)")
        }
    }

    /// Flags the card on screen: 1 red, 2 orange, and so on; 0 takes the
    /// flag off.
    public func flagCurrentCard(_ value: UInt32) async throws {
        guard let cardId = currentCardId else { return }
        try await cardClient.flag(cardId, value)
    }

    public func undo() {
        guard canUndo, !isAdvancing else { return }
        isAdvancing = true

        let collection = self.collection
        let scheduler = self.scheduler
        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let fetchLimit = queueFetchLimit

        Task {
            defer { isAdvancing = false }
            do {
                let queue = try await Task.detached {
                    try collection.undoLast()
                    // Re-fetch queue — Anki places the undone card at the front
                    return try scheduler.getQueuedCards(fetchLimit)
                }.value

                canUndo = false
                undoneCount += 1
                // Roll back session stats only if the operation we just
                // undid was actually an answer. undoLast() undoes the last
                // *collection* operation, and a note edit is reachable from
                // this screen (refreshAfterEdit) — decrementing regardless
                // drove the counters below their true value, and negative.
                if let last = lastRating {
                    sessionStats.reviewed = max(0, sessionStats.reviewed - 1)
                    if last != .again {
                        sessionStats.correct = max(0, sessionStats.correct - 1)
                    }
                    pace.removeLast()
                    if let deck = lastTalliedHomeDeck {
                        newCardsStudied[deck, default: 0] -= 1
                    }
                    if let card = lastAnsweredCard {
                        seenThisSession.remove(card)
                    }
                    if let card = lastProblemCard {
                        problemCards.remove(card)
                    }
                }
                lastRating = nil
                lastTalliedHomeDeck = nil
                lastAnsweredCard = nil
                lastProblemCard = nil

                cardQueue = ReviewQueueOrder.arranged(queue.cards, defersRepeats: defersRepeats, skipping: seenThisSession)
                remainingCounts = DeckCounts(
                    newCount: queue.newCount,
                    learnCount: queue.learningCount,
                    reviewCount: queue.reviewCount
                )
                await advanceToNextCard(notes: notes, notetypes: notetypes, notetypesClient: notetypesClient, cardRendering: cardRendering)
            } catch {
                Log.review.error("Undo failed: \(error)")
            }
        }
    }

    /// Charges the new cards tallied this session to their home decks'
    /// daily limits, then clears the tally. Call once, as the session
    /// closes: the engine call clears the undo history.
    public func recordNewCardsStudied() async {
        let tally = newCardsStudied.filter { $0.value > 0 }
        newCardsStudied = [:]
        lastTalliedHomeDeck = nil
        guard !tally.isEmpty else { return }
        let scheduler = self.scheduler
        await Task.detached {
            for (deck, count) in tally {
                do {
                    try scheduler.recordNewCardsStudied(deck, count)
                } catch {
                    Log.review.error("Recording \(count) new cards for deck \(deck.rawValue) failed: \(error)")
                }
            }
        }.value
    }

    /// Flags the problem cards found this session orange, sending them to
    /// the Graveyard, then clears the list. Call as the session closes.
    /// Returns how many were flagged.
    @discardableResult
    public func flagProblemCards() async -> Int {
        let cards = problemCards
        problemCards = []
        lastProblemCard = nil
        var flagged = 0
        for card in cards {
            do {
                try await cardClient.flag(card, ProblemCardRule.flag)
                flagged += 1
            } catch {
                Log.review.error("Flagging problem card \(card.rawValue) failed: \(error)")
            }
        }
        return flagged
    }

    public func updateAudioPlaying(_ playing: Bool) {
        isAudioPlaying = playing
    }

    public func updateCardChrome(color: Color, isDark: Bool) {
        cardChromeColor = color
        cardChromeIsDark = isDark
    }

    public func bumpReplayRequest() {
        replayRequestID += 1
    }

    public func bumpStopAudioRequest() {
        stopAudioRequestID += 1
    }

    /// Re-renders the current card after the note or template was edited.
    /// The whole engine round-trip runs off the main actor — it used to call
    /// `getNote` and `renderCard` inline, blocking the main thread while the
    /// edit sheet was dismissing.
    public func refreshAfterEdit() async {
        guard let queued = currentQueuedCard else { return }
        invalidatePrefetch()   // the edit may have changed a shared notetype

        let notes = self.notes
        let notetypes = self.notetypes
        let notetypesClient = self.notetypesClient
        let cardRendering = self.cardRendering
        let cache = notetypeCache
        let prepared = await Task.detached {
            await prepareCard(
                for: queued,
                notes: notes,
                notetypes: notetypes,
                cardRendering: cardRendering,
                notetypesClient: notetypesClient,
                notetypeCache: cache
            )
        }.value

        guard currentQueuedCard?.card.id == queued.card.id else { return }

        currentNote = prepared.note
        if let notetype = prepared.notetype {
            notetypeCache[notetype.id] = notetype
        }
        renderedFrontHTML = prepared.renderedFrontHTML
        renderedBackHTML = prepared.renderedBackHTML
        cardCSS = prepared.cardCSS
        typedAnswerState = prepared.typedAnswerState
        templateName = prepared.templateName
        frontHTML = prepared.frontHTML
        backHTML = strippingTypedAnswerPlaceholders(from: prepared.renderedBackHTML)
        reresolveCurrentCard()

        if showAnswer, let state = prepared.typedAnswerState {
            // Re-substitute the back placeholder with the diff; the typed text
            // survives the sheet round-trip in `typedAnswer`.
            let typed = typedAnswer
            let rendered = prepared.renderedBackHTML
            let html = await Task.detached {
                typedAnswerBackHTML(
                    state: state,
                    typedAnswer: typed,
                    renderedBackHTML: rendered,
                    cardRendering: cardRendering
                )
            }.value
            guard currentQueuedCard?.card.id == queued.card.id, showAnswer else { return }
            backHTML = html
        }
    }

    /// Re-runs render-mode resolution for the current card against the
    /// latest engine preference / overrides (RenderModeSheet writes).
    /// Cheap: reuses the already-rendered HTML.
    public func reresolveCurrentCard() {
        // The prefetched card was prepared against the *old* preferences.
        invalidatePrefetch()
        guard let queued = currentQueuedCard else { return }
        let prefs = currentRenderEnginePreferences(mid: currentNote?.mid, ord: Int(queued.card.ord))
        let resolution = resolveRenderMode(
            renderedFront: renderedFrontHTML,
            renderedBack: renderedBackHTML,
            css: cardCSS,
            override: prefs.override,
            global: prefs.global
        )
        resolvedMode = resolution.mode
        resolvedByAuto = resolution.byAuto
    }
}

private extension ReviewSession {
    // MARK: - Private: card advancement

    /// Advances to the next queued card. Pops the queue on the main actor,
    /// then renders the card off the main actor via `Task.detached` and
    /// assigns the resulting state back here. The scheduler/queue mutation
    /// already happened in the caller; this only prepares display state.
    func advanceToNextCard(
        notes: NotesService,
        notetypes: NotetypesService,
        notetypesClient: NotetypesClient,
        cardRendering: CardRenderingService
    ) async {
        guard let next = cardQueue.first else {
            isFinished = true
            currentQueuedCard = nil
            currentNote = nil
            invalidatePrefetch()
            return
        }

        let prepared: PreparedCard
        if let hit = preparedNext, hit.id == next.card.id {
            prepared = hit.card
        } else {
            let cache = notetypeCache
            prepared = await Task.detached {
                await prepareCard(
                    for: next,
                    notes: notes,
                    notetypes: notetypes,
                    cardRendering: cardRendering,
                    notetypesClient: notetypesClient,
                    notetypeCache: cache
                )
            }.value
        }
        preparedNext = nil

        // An undo on the finished screen brings a card back.
        if isFinished { isFinished = false }
        currentQueuedCard = next
        currentNote = prepared.note
        if let notetype = prepared.notetype {
            notetypeCache[notetype.id] = notetype
        }
        resolvedMode = prepared.resolvedMode
        resolvedByAuto = prepared.resolvedByAuto
        templateName = prepared.templateName
        renderedFrontHTML = prepared.renderedFrontHTML
        renderedBackHTML = prepared.renderedBackHTML
        cardCSS = prepared.cardCSS
        typedAnswerState = prepared.typedAnswerState
        typedAnswer = ""
        frontHTML = prepared.frontHTML
        backHTML = prepared.renderedBackHTML  // back substitution happens at reveal
        nextIntervals = next.nextIntervals
        showAnswer = false
        reviewStartTime = .now
        lastFlip = .now
        stopAudioRequestID += 1

        // Spend the user's reading time rendering the card after this one.
        prefetchFollowingCard(
            notes: notes,
            notetypes: notetypes,
            notetypesClient: notetypesClient,
            cardRendering: cardRendering
        )
    }

    // MARK: - Prefetch

    /// Renders the card after the current one while the user reads, into a
    /// single-slot cache. Speculative: the queue is re-fetched on every
    /// answer, so a learning card can resurface and change the head — a miss
    /// just costs the work we would have done anyway.
    func prefetchFollowingCard(
        notes: NotesService,
        notetypes: NotetypesService,
        notetypesClient: NotetypesClient,
        cardRendering: CardRenderingService
    ) {
        prefetchTask?.cancel()
        guard cardQueue.count > 1 else {
            preparedNext = nil
            return
        }
        let next = cardQueue[1]
        guard preparedNext?.id != next.card.id else { return }
        preparedNext = nil

        let cache = notetypeCache
        prefetchTask = Task { [weak self] in
            let prepared = await Task.detached {
                await prepareCard(
                    for: next,
                    notes: notes,
                    notetypes: notetypes,
                    cardRendering: cardRendering,
                    notetypesClient: notetypesClient,
                    notetypeCache: cache
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.preparedNext = (id: next.card.id, card: prepared)
        }
    }

    func invalidatePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        preparedNext = nil
    }

}

#if DEBUG
extension ReviewSession {
    /// Builds a session with canned display state for SwiftUI previews.
    /// Never calls `start()`, so it touches no backend — `ReviewContent`
    /// previews render the card or finished surface deterministically.
    /// Lives in this file so it can set the `private(set)` display state.
    /// Public because `ReviewContent`'s previews live in the app target.
    public static func preview(
        showAnswer: Bool = false,
        isFinished: Bool = false,
        front: String = "<div class=\"card\">猫</div>",
        back: String = "<div class=\"card\">猫<hr>cat — a small domesticated feline</div>",
        reviewed: Int = 7,
        counts: DeckCounts = DeckCounts(newCount: 5, learnCount: 2, reviewCount: 13)
    ) -> ReviewSession {
        let session = ReviewSession(deckId: DeckID(1))
        session.frontHTML = front
        session.backHTML = back
        session.cardCSS = """
        .card { font-family: -apple-system; font-size: 30px; text-align: center; padding: 24px; }
        hr { margin: 20px 0; border: none; border-top: 1px solid #ccc; }
        """
        session.showAnswer = showAnswer
        session.isFinished = isFinished
        session.sessionStats = SessionStats(reviewed: reviewed, correct: 6, totalTimeMs: 42_000)
        for _ in 0..<max(reviewed, 0) {
            session.pace.record(milliseconds: 6_000, missed: false)
        }
        session.remainingCounts = counts
        session.deckName = "한국어 · Vocab Typing"
        session.nextIntervals = [.again: "<1m", .hard: "8m", .good: "1d", .easy: "4d"]
        session.canUndo = reviewed > 0
        session.templateName = "Card 1"
        return session
    }
}
#endif
