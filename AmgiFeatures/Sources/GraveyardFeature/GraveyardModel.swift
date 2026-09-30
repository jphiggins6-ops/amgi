//
//  GraveyardModel.swift
//  GraveyardFeature
//

import OSLog
import AnkiClients
import AnkiKit
import AppCore
import Dependencies
import Foundation
import MnemonicCore
import Observation

/// One flagged card in the Graveyard list.
struct GraveyardItem: Identifiable, Equatable, Hashable, Sendable {
    let cardId: CardID
    let noteId: NoteID
    /// Anki's flag number: 1 red, 2 orange.
    let flag: UInt32
    /// The note's first field, as one readable line.
    let front: String
    let deckName: String

    var id: CardID { cardId }
}

/// Loads every red- or orange-flagged card, however long overdue, and
/// whether or not it is suspended or buried.
@Observable
@MainActor
final class GraveyardModel {
    enum State: Equatable {
        case loading
        case loaded([GraveyardItem])
        case failed(String)
    }

    private(set) var state: State = .loading

    @ObservationIgnored @Dependency(\.cardClient) private var cardClient
    @ObservationIgnored @Dependency(\.noteClient) private var noteClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient

    /// Anki's flags 1 and 2, red and orange.
    static let search = "flag:1 OR flag:2"

    func load() async {
        do {
            let ids = try await cardClient.search(Self.search)
            let deckNames = Dictionary(
                ((try? await deckClient.fetchAll()) ?? []).map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            var items: [GraveyardItem] = []
            items.reserveCapacity(ids.count)
            for id in ids {
                let card = try await cardClient.fetch(id)
                let note = try await noteClient.fetch(card.nid)
                let firstField = note.map { CardFieldEdits.splitFields($0.flds).first ?? "" } ?? ""
                // A card in a filtered deck is named after its home deck.
                let homeDeck = card.odid.rawValue != 0 ? card.odid : card.did
                items.append(GraveyardItem(
                    cardId: id,
                    noteId: card.nid,
                    flag: UInt32(truncatingIfNeeded: card.flags) & 0b111,
                    front: MnemonicText.summary(firstField, limit: 120),
                    deckName: deckNames[homeDeck] ?? ""
                ))
            }
            state = .loaded(Self.sorted(items))
        } catch {
            Log.decks.error("Graveyard load failed: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Red before orange, then by deck, then by the card's text.
    static func sorted(_ items: [GraveyardItem]) -> [GraveyardItem] {
        items.sorted { lhs, rhs in
            if lhs.flag != rhs.flag { return lhs.flag < rhs.flag }
            if lhs.deckName != rhs.deckName {
                return lhs.deckName.localizedStandardCompare(rhs.deckName) == .orderedAscending
            }
            return lhs.front.localizedStandardCompare(rhs.front) == .orderedAscending
        }
    }
}
