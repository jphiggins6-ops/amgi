//
//  CardVoiceSides.swift
//  ReviewCore
//

public import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import Foundation

/// Cards' sides as the review screen shows them, rendered outside a review
/// so hands-free mode's AI voice can be made ready before the cards come
/// up. The HTML is what `prepareCard` gives a review, so what's made ready
/// is what's read.
public final class CardVoiceSides: Sendable {
    private let cards: CardClient
    private let notes: NotesService
    private let notetypes: NotetypesClient
    private let rendering: CardRenderingService

    public init() {
        @Dependency(\.cardClient) var cards
        @Dependency(\.notesService) var notes
        @Dependency(\.notetypesClient) var notetypes
        @Dependency(\.cardRenderingService) var rendering
        self.cards = cards
        self.notes = notes
        self.notetypes = notetypes
        self.rendering = rendering
    }

    /// Every card that isn't suspended, the soonest due first: cards being
    /// learned and those due now, then the reviews due on each of the next
    /// `days` days, with new cards worked in at `newPerDay` a day in the
    /// order they'll be introduced, then the rest.
    public func cardIdsByDueDate(newPerDay: Int, days: Int = 60) async throws -> [CardID] {
        let unsuspended = "-is:suspended"
        var ordered: [CardID] = []
        var seen: Set<CardID> = []
        func add(_ ids: [CardID]) {
            for id in ids where seen.insert(id).inserted {
                ordered.append(id)
            }
        }

        // A new card's due is its place in the order new cards come in.
        var waitingNew: [(id: CardID, position: Int32)] = []
        for id in try await cards.search("is:new \(unsuspended)") {
            if let card = try? await cards.fetch(id) {
                waitingNew.append((id: id, position: card.due))
            }
        }
        var newCards = waitingNew.sorted { $0.position < $1.position }.map(\.id)[...]
        let perDay = max(newPerDay, 0)
        func addNew() {
            add(Array(newCards.prefix(perDay)))
            newCards = newCards.dropFirst(perDay)
        }

        add(try await cards.search("is:learn \(unsuspended)"))
        add(try await cards.search("is:due \(unsuspended)"))
        addNew()
        for day in 1...max(days, 1) {
            add(try await cards.search("prop:due=\(day) \(unsuspended)"))
            addNew()
        }
        add(Array(newCards))
        add(try await cards.search(unsuspended))
        return ordered
    }

    /// The card's question side and answer side, nil when it can't be
    /// rendered. Off the main actor, like a review's.
    public func sides(of cardId: CardID) async -> (front: String, back: String)? {
        let cards = self.cards
        let notes = self.notes
        let notetypes = self.notetypes
        let rendering = self.rendering
        return await Task.detached { () async -> (front: String, back: String)? in
            do {
                let card = try await cards.fetch(cardId)
                let note = try notes.getNote(card.nid)
                let notetype = try? await notetypes.get(note.mid)
                let rendered = try rendering.renderCard(cardId)
                let back = ExtraFieldMarker.marking(
                    rendered.backHTML,
                    fieldNames: notetype?.fields.map(\.name) ?? [],
                    fieldValues: note.flds.components(separatedBy: "\u{1f}")
                )
                return (
                    front: strippingTypedAnswerPlaceholders(from: rendered.frontHTML),
                    back: strippingTypedAnswerPlaceholders(from: back)
                )
            } catch {
                return nil
            }
        }.value
    }
}
