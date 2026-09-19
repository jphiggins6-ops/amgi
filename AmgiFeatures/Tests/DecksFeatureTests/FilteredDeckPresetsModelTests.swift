//
//  FilteredDeckPresetsModelTests.swift
//  DecksFeatureTests
//

import Foundation
import Testing
import AnkiKit
import AnkiClients
import AppCore
import Dependencies
@testable import DecksFeature

@MainActor
@Suite struct FilteredDeckPresetsModelTests {

    // MARK: - tree projection

    @Test func filteredDecksByName_keysOnFullNameAndSkipsNormalDecks() {
        let tree = [
            node(id: 1, name: "Korean", children: [
                node(id: 2, name: "Vocab", fullName: "Korean::Vocab"),
                node(id: 3, name: "Cram", fullName: "Korean::Cram", isFiltered: true),
            ]),
            node(id: 4, name: "Leeches", isFiltered: true),
        ]

        let byName = FilteredDeckPresetsModel.filteredDecksByName(tree)

        #expect(byName.keys.sorted() == ["Korean::Cram", "Leeches"])
        #expect(byName["Korean::Cram"]?.id == DeckID(3))
        #expect(byName["Korean"] == nil, "a normal deck must never shadow a preset's name")
    }

    @Test func countsByDeck_flattensTheWholeTree() {
        let tree = [
            node(
                id: 1,
                name: "Korean",
                counts: DeckCounts(newCount: 1, learnCount: 0, reviewCount: 2),
                children: [
                    node(
                        id: 2,
                        name: "Vocab",
                        fullName: "Korean::Vocab",
                        counts: DeckCounts(newCount: 0, learnCount: 4, reviewCount: 0)
                    ),
                ]
            )
        ]

        let counts = FilteredDeckPresetsModel.countsByDeck(tree)

        #expect(counts[DeckID(1)]?.total == 3)
        #expect(counts[DeckID(2)]?.total == 4)
    }

    // MARK: - build

    @Test func build_updatesADeckAlreadyCarryingThePresetsName() async {
        let store = scratchStore(presets: [
            FilteredDeckPreset(name: "Leeches", searchQuery: "is:due tag:leech", limit: 25, order: .lapses),
            FilteredDeckPreset(name: "Fresh", searchQuery: "added:1"),
        ])
        let model = FilteredDeckPresetsModel(store: store)
        let recorder = SpecRecorder()

        let tree = [
            node(id: 1, name: "Default"),
            node(
                id: 5,
                name: "Leeches",
                isFiltered: true,
                counts: DeckCounts(newCount: 0, learnCount: 0, reviewCount: 7)
            ),
        ]

        await withDependencies {
            $0.deckClient = DeckClient(
                fetchTree: { tree },
                createFilteredDeck: { spec in
                    recorder.record(spec)
                    // Mirrors the engine: id 0 means "create", and the new
                    // deck's id comes back on the response.
                    return DeckCreation(
                        id: spec.id == DeckID(0) ? DeckID(99) : spec.id,
                        changes: CollectionChanges(deck: true)
                    )
                }
            )
        } operation: {
            await model.build()
        }

        #expect(
            recorder.specs.map(\.id) == [DeckID(5), DeckID(0)],
            "an existing filtered deck of the same name is updated; a new name creates"
        )
        #expect(recorder.specs[0].searchTerms == [
            FilteredDeckSearchTerm(search: "is:due tag:leech", limit: 25, order: .lapses)
        ])
        #expect(model.results.map(\.name) == ["Leeches", "Fresh"])
        #expect(model.results[0].outcome == .built(cardCount: 7))
        #expect(model.results[1].outcome == .built(cardCount: 0))
        #expect(model.isBuilding == false)
    }

    @Test func build_keepsTheDecksThatSucceededWhenOneFails() async {
        let store = scratchStore(presets: [
            FilteredDeckPreset(name: "Good", searchQuery: "is:due"),
            FilteredDeckPreset(name: "Bad", searchQuery: "tag:nothing-matches-this"),
        ])
        let model = FilteredDeckPresetsModel(store: store)

        await withDependencies {
            $0.deckClient = DeckClient(
                fetchTree: { [] },
                createFilteredDeck: { spec in
                    if spec.name == "Bad" { throw StubBuildError() }
                    return DeckCreation(id: DeckID(42), changes: CollectionChanges(deck: true))
                }
            )
        } operation: {
            await model.build()
        }

        #expect(model.results.count == 2)
        #expect(model.results[0].outcome == .built(cardCount: 0))
        #expect(model.results[1].outcome == .failed("no cards matched your search"))
    }

    @Test func build_doesNothingWithAnEmptySelection() async {
        let store = scratchStore(presets: [
            FilteredDeckPreset(name: "Leeches", searchQuery: "is:due tag:leech")
        ])
        let model = FilteredDeckPresetsModel(store: store)
        model.selection = []

        await withDependencies {
            $0.deckClient = DeckClient(
                fetchTree: { Issue.record("no tree read without a selection"); return [] },
                createFilteredDeck: { _ in
                    Issue.record("nothing to build")
                    return DeckCreation(id: DeckID(0), changes: CollectionChanges())
                }
            )
        } operation: {
            await model.build()
        }

        #expect(model.results.isEmpty)
    }

    @Test func newModelSelectsEveryStoredPreset() {
        let store = scratchStore(presets: [
            FilteredDeckPreset(name: "A", searchQuery: "is:due"),
            FilteredDeckPreset(name: "B", searchQuery: "is:new"),
        ])
        let model = FilteredDeckPresetsModel(store: store)
        #expect(model.selection == Set(store.presets.map(\.id)))
    }

    @Test func forgetDropsThePresetItsSelectionAndItsResult() {
        let store = scratchStore(presets: [
            FilteredDeckPreset(name: "A", searchQuery: "is:due")
        ])
        let model = FilteredDeckPresetsModel(store: store)
        let id = store.presets[0].id

        model.forget(id: id)

        #expect(store.presets.isEmpty)
        #expect(!model.selection.contains(id))
    }
}

// MARK: - Fixtures

private extension FilteredDeckPresetsModelTests {
    /// `fullName` is what a preset's name is matched against, so it is
    /// spelled out rather than derived — deriving it here would test the
    /// fixture instead of the projection.
    func node(
        id: Int64,
        name: String,
        fullName: String? = nil,
        isFiltered: Bool = false,
        counts: DeckCounts = .zero,
        children: [DeckTreeNode] = []
    ) -> DeckTreeNode {
        DeckTreeNode(
            id: DeckID(id),
            name: name,
            fullName: fullName ?? name,
            counts: counts,
            isFiltered: isFiltered,
            children: children
        )
    }

    /// A store on its own defaults domain, loaded with exactly these
    /// presets — the starter pack would otherwise decide the fixtures.
    func scratchStore(presets: [FilteredDeckPreset]) -> FilteredDeckPresetStore {
        let suite = "FilteredDeckPresetsModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = FilteredDeckPresetStore(defaults: defaults, profileID: "test")
        for existing in store.presets {
            store.delete(id: existing.id)
        }
        for preset in presets {
            store.add(preset)
        }
        return store
    }
}

private struct StubBuildError: Error, LocalizedError {
    var errorDescription: String? { "no cards matched your search" }
}

private final class SpecRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FilteredDeckSpec] = []

    func record(_ spec: FilteredDeckSpec) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(spec)
    }

    var specs: [FilteredDeckSpec] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
