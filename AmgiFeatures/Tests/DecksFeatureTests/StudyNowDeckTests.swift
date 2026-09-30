//
//  StudyNowDeckTests.swift
//  DecksFeatureTests
//

import Foundation
import Testing
import AnkiKit
import AnkiClients
import Dependencies
@testable import DecksFeature

@MainActor
@Suite struct StudyNowDeckTests {

    // MARK: - Reviews

    @Test func reviewsGatherEveryDueUnflaggedCardOutsidePInRandomOrder() async throws {
        let specs = Recorder<FilteredDeckSpec>()
        var deckClient = DeckClient()
        deckClient.fetchTree = { [] }
        deckClient.createFilteredDeck = { spec in
            specs.record(spec)
            return DeckCreation(id: DeckID(77), changes: CollectionChanges(deck: true))
        }

        let id = try await withDependencies {
            $0.deckClient = deckClient
        } operation: {
            try await DeckListModel().buildStudyNowDeck(.reviews)
        }

        #expect(id == DeckID(77))
        let spec = try #require(specs.all.first)
        #expect(spec.id == DeckID(0), "no Study Now deck yet, so one is created")
        #expect(spec.name == "Study Now")
        #expect(spec.searchTerms == [
            FilteredDeckSearchTerm(search: "is:due flag:0 -deck:p", limit: 9999, order: .random)
        ])
        #expect(spec.reschedule, "answers must count as they would in the card's home deck")
    }

    @Test func reviewsRebuildTheExistingStudyNowDeckInPlace() async throws {
        let specs = Recorder<FilteredDeckSpec>()
        var deckClient = DeckClient()
        deckClient.fetchTree = { [Self.deck(1, "Default"), Self.deck(12, "Study Now", isFiltered: true)] }
        deckClient.createFilteredDeck = { spec in
            specs.record(spec)
            return DeckCreation(id: spec.id, changes: CollectionChanges(deck: true))
        }

        _ = try await withDependencies {
            $0.deckClient = deckClient
        } operation: {
            try await DeckListModel().buildStudyNowDeck(.reviews)
        }

        #expect(specs.all.map(\.id) == [DeckID(12)])
    }

    // MARK: - New cards

    @Test func newCardsComeFromEachDecksOwnQueueAndAreShuffledTogether() async throws {
        let specs = Recorder<FilteredDeckSpec>()
        let emptied = Recorder<DeckID>()
        let fetched = Recorder<String>()
        let tree = [
            Self.deck(1, "Korean", new: 2, review: 3),
            Self.deck(2, "p", new: 5),
            Self.deck(3, "Finished", review: 4),
            Self.deck(4, "Neuro", new: 1),
            Self.deck(12, "Study Now", isFiltered: true, review: 9),
        ]
        var deckClient = DeckClient()
        deckClient.fetchTree = { tree }
        deckClient.emptyFilteredDeck = { id in emptied.record(id) }
        deckClient.createFilteredDeck = { spec in
            specs.record(spec)
            return DeckCreation(id: spec.id, changes: CollectionChanges(deck: true))
        }
        var cardClient = CardClient()
        cardClient.fetchQueue = { deckId, limit in
            fetched.record("\(deckId.rawValue):\(limit)")
            switch deckId.rawValue {
            case 1:
                // A review, a new card, a learning card, another new card.
                return [Self.card(10, queue: 2), Self.card(11, queue: 0), Self.card(12, queue: 1), Self.card(13, queue: 0)]
            case 4:
                return [Self.card(40, queue: 0)]
            default:
                return []
            }
        }

        _ = try await withDependencies {
            $0.deckClient = deckClient
            $0.cardClient = cardClient
        } operation: {
            try await DeckListModel().buildStudyNowDeck(.newCards)
        }

        #expect(emptied.all == [DeckID(12)], "an unfinished session's cards go home before picking")
        #expect(fetched.all == ["1:5", "4:1"], "p, decks with no new cards left, and filtered decks are skipped")
        let spec = try #require(specs.all.first)
        #expect(spec.id == DeckID(12))
        #expect(spec.searchTerms == [
            FilteredDeckSearchTerm(search: "cid:11,13,40", limit: 3, order: .random)
        ])
        #expect(spec.reschedule)
    }

    @Test func noNewCardsLeftIsAnError() async throws {
        var deckClient = DeckClient()
        deckClient.fetchTree = { [Self.deck(1, "Korean", review: 3), Self.deck(2, "p", new: 5)] }

        await #expect(throws: DeckListModel.StudyNowError.noNewCards) {
            try await withDependencies {
                $0.deckClient = deckClient
            } operation: {
                try await DeckListModel().buildStudyNowDeck(.newCards)
            }
        }
    }

    @Test func theNewCountSumsTopLevelDecksOutsidePAndFilteredDecks() {
        let tree = [
            Self.deck(1, "Korean", new: 20, review: 3),
            Self.deck(2, "P", new: 5),
            Self.deck(4, "Neuro", new: 7),
            Self.deck(12, "Study Now", isFiltered: true, new: 9),
        ]
        #expect(DeckListModel.newCardsToday(in: tree) == 27)
    }
}

// MARK: - Fixtures

// `nonisolated`: the stubbed clients call these from their @Sendable
// closures, off the suite's main actor.
private extension StudyNowDeckTests {
    nonisolated static func deck(
        _ id: Int64,
        _ name: String,
        isFiltered: Bool = false,
        new: Int = 0,
        review: Int = 0
    ) -> DeckTreeNode {
        DeckTreeNode(
            id: DeckID(id),
            name: name,
            fullName: name,
            counts: DeckCounts(newCount: new, learnCount: 0, reviewCount: review),
            isFiltered: isFiltered,
            children: []
        )
    }

    nonisolated static func card(_ id: Int64, queue: Int16) -> CardRecord {
        CardRecord(id: CardID(id), nid: NoteID(id), did: DeckID(1), mod: 0, queue: queue)
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
