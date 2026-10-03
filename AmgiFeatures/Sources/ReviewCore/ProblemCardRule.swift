//
//  ProblemCardRule.swift
//  ReviewCore
//

public import AnkiKit

/// When a card counts as a problem card: forgotten again and again, which
/// usually means it's badly written rather than badly learned. Problem
/// cards are flagged orange, which puts them in the Graveyard.
public enum ProblemCardRule {
    /// Anki's orange flag; red stays the user's own "this is defective".
    public static let flag: UInt32 = 2

    /// Whether this answer makes `card` a problem card: it's a review card
    /// being forgotten (Again), which takes its lapses to `threshold` or
    /// more, and it has no flag yet. A threshold of 0 turns it off.
    public static func isProblem(after rating: Rating, on card: CardRecord, threshold: Int) -> Bool {
        guard threshold > 0, rating == .again else { return false }
        // Type 2 is a review card; a lapse is a review card forgotten.
        // Cards still being learned or relearned don't add to it.
        guard card.type == 2 else { return false }
        guard card.flags & 0b111 == 0 else { return false }
        return Int(card.lapses) + 1 >= threshold
    }

    /// Cards already forgotten `threshold` times or more, unflagged and
    /// outside deck "p": what to send when the rule is first switched on.
    public static func existingSearch(threshold: Int) -> String {
        "prop:lapses>=\(max(threshold, 1)) flag:0 -deck:p"
    }
}
