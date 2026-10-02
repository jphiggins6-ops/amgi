//
//  ReviewQueueOrder.swift
//  ReviewCore
//

import AnkiKit

/// Decides the order the reviewer walks the engine's queued cards in.
///
/// The engine returns learning cards that are due now first, then the
/// day's new and review cards, then learning cards inside the learn-ahead
/// window. A card missed a minute ago therefore jumps ahead of cards not
/// yet seen today. With `defersRepeats`, cards in (re)learning wait until
/// every other due card has been shown once.
///
/// Only the order changes; each answer is still scheduled by the engine at
/// the moment it is given. The engine accepts an answer for any learning
/// card or for the head of its main queue, and the first non-learning card
/// in its list is always that head, so every card placed first here can be
/// answered.
enum ReviewQueueOrder {
    /// - Parameter seen: cards to leave out altogether, for a session that
    ///   shows each card once (`ReviewSession.showsEachCardOnce`). Leaving
    ///   them out keeps the first card answerable: a card answered today is
    ///   never back in the engine's main queue the same day (it's in
    ///   learning, or due another day), so the first non-learning card left
    ///   is still the main queue's head.
    static func arranged(
        _ cards: [QueuedReviewCard],
        defersRepeats: Bool,
        skipping seen: Set<CardID> = []
    ) -> [QueuedReviewCard] {
        let unseen = seen.isEmpty ? cards : cards.filter { !seen.contains($0.card.id) }
        guard defersRepeats else { return unseen }
        let firstLooks = unseen.filter { !isIntradayLearning($0.card) }
        let repeats = unseen.filter { isIntradayLearning($0.card) }
        return firstLooks + repeats
    }

    /// Anki's `Learn` (1) and `PreviewRepeat` (4) queues: the cards the
    /// engine brings back later the same day. Interday learning (3) is
    /// served from the main queue along with new (0) and review (2) cards.
    static func isIntradayLearning(_ card: CardRecord) -> Bool {
        card.queue == 1 || card.queue == 4
    }
}
