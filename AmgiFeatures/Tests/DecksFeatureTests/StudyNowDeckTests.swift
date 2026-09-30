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

    @Test func gathersEveryDueUnflaggedCardOutsidePInRandomOrder() async throws {
        let specs = StudyNowSpecs()

        let id = try await withDependencies {
            $0.deckClient = DeckClient(
                fetchTree: { [] },
                createFilteredDeck: { spec in
                    specs.record(spec)
                    return DeckCreation(id: DeckID(77), changes: CollectionChanges(deck: true))
                }
            )
        } operation: {
            try await DeckListModel().buildStudyNowDeck()
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

    @Test func rebuildsTheExistingStudyNowDeckInPlace() async throws {
        let specs = StudyNowSpecs()
        let tree = [
            DeckTreeNode(id: DeckID(1), name: "Default", fullName: "Default", counts: .zero, isFiltered: false, children: []),
            DeckTreeNode(id: DeckID(12), name: "Study Now", fullName: "Study Now", counts: .zero, isFiltered: true, children: []),
        ]

        _ = try await withDependencies {
            $0.deckClient = DeckClient(
                fetchTree: { tree },
                createFilteredDeck: { spec in
                    specs.record(spec)
                    return DeckCreation(id: spec.id, changes: CollectionChanges(deck: true))
                }
            )
        } operation: {
            try await DeckListModel().buildStudyNowDeck()
        }

        #expect(specs.all.map(\.id) == [DeckID(12)])
    }
}

private final class StudyNowSpecs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FilteredDeckSpec] = []

    func record(_ spec: FilteredDeckSpec) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(spec)
    }

    var all: [FilteredDeckSpec] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
