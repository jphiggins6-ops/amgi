//
//  ReviewDestination.swift
//  ReviewFeature
//
//  Created by Vladimir Gusev on 18.08.2026.
//

import Foundation
import CasePaths
import AnkiKit
import MnemonicCore
import ReviewCore

/// Single source of truth for every modal axis on the review screen: the note
/// editor, the template editor, the dictionary lookup popup, and the ✨
/// visual-mnemonic capture sheet.
///
/// Replaces three independent optionals (`editingNote`, `editingTemplate`,
/// `lookupQuery`) threaded down as three bindings, which between them could
/// encode states the screen has no rendering for — two editors asking to show
/// at once, or a lookup raised behind one.
///
/// It also retires `ReviewLookupQuery`: the toolbar's "Look Up" opens the
/// popup with no query yet, which `.sheet(item:)` could only express by
/// wrapping the string in an `Identifiable` box. Presence is the case here,
/// so `.lookup("")` is a perfectly good presented state.
@CasePathable
enum ReviewDestination {
    case editNote(NoteRecord)
    case editTemplate(ReviewSession.TemplateTarget)
    case lookup(String)
    case captureMnemonic(NoteRecord)
    /// "Explain": the AI's take on why the answer is right.
    case explain(CardExplanation.Card)
    /// How the card is drawn: the built-in renderer or its own template.
    /// Opened from ⋯ (it used to be a bar above every card).
    case renderMode
}

extension Optional where Wrapped == ReviewDestination {
    var lookupText: String? {
        get {
            guard case .lookup(let text) = self else { return nil }
            return text
        }
        set { self = newValue.map(ReviewDestination.lookup) }
    }
}
