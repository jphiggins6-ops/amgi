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
/// editor, the template editor, the ✨ visual-mnemonic capture sheet and the
/// rest, so two can't ask to show at once. (The dictionary lookup that was
/// here is gone from reviews: a tap on a word opened it when the tap was
/// meant for the tap areas.)
@CasePathable
enum ReviewDestination {
    case editNote(NoteRecord)
    case editTemplate(ReviewSession.TemplateTarget)
    case captureMnemonic(NoteRecord)
    /// "Explain": the AI's take on why the answer is right.
    case explain(CardExplanation.Card)
    /// How the card is drawn: the built-in renderer or its own template.
    /// Opened from ⋯ (it used to be a bar above every card).
    case renderMode
}
