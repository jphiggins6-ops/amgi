//
//  SchedulerTypes.swift
//  AnkiKit
//
//  Created by Vladimir Gusev on 01.04.2026.
//

package import Foundation

/// Opaque wrapper for a serialized proto SchedulingState. App code holds these
/// but cannot inspect them; AnkiServices reads/writes the bytes internally.
public struct SchedulingStateToken: Sendable {
    package let bytes: Data
    package init(_ bytes: Data) { self.bytes = bytes }
}

public struct ReviewSchedulingStates: Sendable {
    public let current: SchedulingStateToken
    public let again: SchedulingStateToken
    public let hard: SchedulingStateToken
    public let good: SchedulingStateToken
    public let easy: SchedulingStateToken

    package init(
        current: SchedulingStateToken,
        again: SchedulingStateToken,
        hard: SchedulingStateToken,
        good: SchedulingStateToken,
        easy: SchedulingStateToken
    ) {
        self.current = current
        self.again = again
        self.hard = hard
        self.good = good
        self.easy = easy
    }
}

public struct QueuedReviewCard: Sendable {
    public let card: CardRecord
    public let states: ReviewSchedulingStates
    public let nextIntervals: [Rating: String]

    package init(card: CardRecord, states: ReviewSchedulingStates, nextIntervals: [Rating: String]) {
        self.card = card
        self.states = states
        self.nextIntervals = nextIntervals
    }

    /// Convenience factory for tests and SwiftUI previews.
    /// `queue` is the card's Anki queue: 0 new, 1 learning, 2 review. A
    /// non-zero `originalDeckId` puts the card in a filtered deck, with
    /// that as its home deck. `type` is the card's Anki type (2 review) and
    /// `lapses` how often it has been forgotten.
    public static func preview(
        cardId: CardID,
        noteId: NoteID,
        ord: Int32,
        queue: Int16 = 0,
        originalDeckId: DeckID = DeckID(0),
        type: Int16 = 0,
        lapses: Int32 = 0
    ) -> QueuedReviewCard {
        let emptyToken = SchedulingStateToken(Data())
        let states = ReviewSchedulingStates(
            current: emptyToken, again: emptyToken,
            hard: emptyToken, good: emptyToken, easy: emptyToken
        )
        let card = CardRecord(
            id: cardId, nid: noteId, did: DeckID(1), ord: ord, mod: 0, type: type, queue: queue,
            lapses: lapses, odid: originalDeckId
        )
        return QueuedReviewCard(card: card, states: states, nextIntervals: [:])
    }
}

/// A card's scheduling states as the engine works them out now, under its
/// deck's settings as they are, with the interval each answer gives.
public struct CardSchedulingStates: Sendable {
    public let states: ReviewSchedulingStates
    public let nextIntervals: [Rating: String]

    package init(states: ReviewSchedulingStates, nextIntervals: [Rating: String]) {
        self.states = states
        self.nextIntervals = nextIntervals
    }
}

extension QueuedReviewCard {
    /// The same card as it is now (`card`), with `fresh` states: after it
    /// moved to a deck with other settings mid-review, say, when the
    /// engine no longer takes an answer made with the states it was
    /// queued with.
    public func updated(card: CardRecord, scheduling fresh: CardSchedulingStates) -> QueuedReviewCard {
        QueuedReviewCard(card: card, states: fresh.states, nextIntervals: fresh.nextIntervals)
    }
}

public struct QueuedCardsResult: Sendable {
    public let cards: [QueuedReviewCard]
    public let newCount: Int
    public let learningCount: Int
    public let reviewCount: Int

    public init(cards: [QueuedReviewCard], newCount: Int, learningCount: Int, reviewCount: Int) {
        self.cards = cards
        self.newCount = newCount
        self.learningCount = learningCount
        self.reviewCount = reviewCount
    }
}

public struct RenderedCard: Sendable {
    public let frontHTML: String
    public let backHTML: String
    public let cardCSS: String

    public init(frontHTML: String, backHTML: String, cardCSS: String) {
        self.frontHTML = frontHTML
        self.backHTML = backHTML
        self.cardCSS = cardCSS
    }
}

public struct TypedAnswerState: Sendable, Equatable {
    public let placeholder: String
    public let expected: String
    public let combining: Bool
    public let fontName: String
    public let fontSize: Int

    public init(placeholder: String, expected: String, combining: Bool, fontName: String, fontSize: Int) {
        self.placeholder = placeholder
        self.expected = expected
        self.combining = combining
        self.fontName = fontName
        self.fontSize = fontSize
    }
}
