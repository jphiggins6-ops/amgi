//
//  StudyRound.swift
//  ReviewFeature
//

/// A round from one of the Library's study buttons: every card in its deck
/// shown once, counted against the whole day, ending in a moment's
/// celebration and a return to the Library rather than a summary screen.
///
/// Today's minimum is two rounds, Reviews and New. Once Reviews is done,
/// the same button offers `again` rounds of the cards seen today that are
/// due again, as often as wanted.
package struct StudyRound: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// The first look today at every due card.
        case reviews
        /// Today's new cards.
        case newCards
        /// Another look at cards seen today that are due again.
        case again
    }

    package let kind: Kind
    /// Cards of today's round done before this session, from earlier
    /// sessions today or another device.
    package let doneEarlierToday: Int
    /// Whether the other half of today's minimum is already done, so that
    /// finishing this round finishes the day.
    package let finishesTheDay: Bool

    package init(kind: Kind, doneEarlierToday: Int = 0, finishesTheDay: Bool = false) {
        self.kind = kind
        self.doneEarlierToday = doneEarlierToday
        self.finishesTheDay = finishesTheDay
    }

    /// What the finish says, e.g. "Done for today".
    var finishTitle: String {
        switch kind {
        case .reviews: finishesTheDay ? "Done for today" : "Reviews done"
        case .newCards: finishesTheDay ? "Done for today" : "New cards done"
        case .again: "Round done"
        }
    }

    var finishMessage: String {
        switch kind {
        case .reviews:
            finishesTheDay
                ? "Every card due today has had its turn, and today's new cards are learned."
                : "Every card due today has had its turn. Today's new cards are next."
        case .newCards:
            finishesTheDay
                ? "Today's new cards are learned, and every card due today has had its turn."
                : "Today's new cards are learned. Today's reviews are still waiting."
        case .again:
            "Cards you've seen today come back to Reviews as they fall due again."
        }
    }

    /// The day's minimum gets a seal; anything less, a tick.
    var finishSymbol: String {
        finishesTheDay && kind != .again ? "checkmark.seal.fill" : "checkmark.circle.fill"
    }
}
