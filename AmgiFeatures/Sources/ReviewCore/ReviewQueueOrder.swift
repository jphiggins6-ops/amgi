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
    static func arranged(_ cards: [QueuedReviewCard], defersRepeats: Bool) -> [QueuedReviewCard] {
        guard defersRepeats else { return cards }
        let firstLooks = cards.filter { !isIntradayLearning($0.card) }
        let repeats = cards.filter { isIntradayLearning($0.card) }
        return firstLooks + repeats
    }

    /// Anki's `Learn` (1) and `PreviewRepeat` (4) queues: the cards the
    /// engine brings back later the same day. Interday learning (3) is
    /// served from the main queue along with new (0) and review (2) cards.
    static func isIntradayLearning(_ card: CardRecord) -> Bool {
        card.queue == 1 || card.queue == 4
    }
}
