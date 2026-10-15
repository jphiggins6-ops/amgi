//
//  StudyRound.swift
//  ReviewFeature
//

package import AppCore

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
        /// The Peripheral Nerve Examination deck's own buttons (`NerveExam`):
        /// its due cards, or its new ones. Not part of today's minimum.
        case nerveExam(newCards: Bool)
    }

    package let kind: Kind
    /// Cards of today's round done before this session, from earlier
    /// sessions today or another device.
    package let doneEarlierToday: Int
    /// Whether the rest of today's minimum is already done, so that
    /// finishing this round finishes the day.
    package let finishesTheDay: Bool
    /// Long Answers cards past their grace (`LongAnswers`): the part of
    /// today's minimum that has a button of its own.
    package let longAnswersRequired: Int

    package init(kind: Kind, doneEarlierToday: Int = 0, finishesTheDay: Bool = false, longAnswersRequired: Int = 0) {
        self.kind = kind
        self.doneEarlierToday = doneEarlierToday
        self.finishesTheDay = finishesTheDay
        self.longAnswersRequired = longAnswersRequired
    }

    /// What the finish says, e.g. "Done for today".
    var finishTitle: String {
        switch kind {
        case .reviews: finishesTheDay ? "Done for today" : "Reviews done"
        case .newCards: finishesTheDay ? "Done for today" : "New cards done"
        case .again: "Round done"
        case .nerveExam(let newCards): newCards ? "New cards done" : "Reviews done"
        }
    }

    var finishMessage: String {
        if !finishesTheDay, longAnswersRequired > 0, kind == .reviews || kind == .newCards {
            let cards = longAnswersRequired == 1 ? "1 Long Answers card has" : "\(longAnswersRequired) Long Answers cards have"
            let done = kind == .reviews ? "Every card due today has had its turn." : "Today's new cards are learned."
            return "\(done) \(cards) waited 3 days past due, so \(longAnswersRequired == 1 ? "it's" : "they're") needed to finish today."
        }
        return switch kind {
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
        case .nerveExam(let newCards):
            newCards
                ? "Today's new Peripheral Nerve Examination cards are learned. They're extra: today's minimum doesn't need them."
                : "Every Peripheral Nerve Examination card due has had its turn. They're extra: today's minimum doesn't need them."
        }
    }

    /// Today's numbers with `cardsLeft` of this round still to go: what the
    /// Today widget and the app icon show when the app is left mid-round.
    /// Nil for an `again` round, which isn't part of today's minimum.
    package func progress(_ today: TodaySnapshot, cardsLeft: Int) -> TodaySnapshot? {
        var updated = today
        switch kind {
        case .reviews:
            updated.reviewsLeft = min(cardsLeft, today.reviewsTotal)
        case .newCards:
            updated.newLeft = min(cardsLeft, today.newTotal)
        case .again, .nerveExam:
            return nil
        }
        return updated
    }

    /// The day's minimum gets a seal; anything less, a tick.
    var finishSymbol: String {
        finishesTheDay && (kind == .reviews || kind == .newCards) ? "checkmark.seal.fill" : "checkmark.circle.fill"
    }
}
