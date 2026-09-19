//
//  FilteredDeckPresetStoreTests.swift
//  AppCoreTests
//

import Foundation
import Testing
import AnkiKit
@testable import AppCore

@MainActor
@Suite struct FilteredDeckPresetStoreTests {
    /// Each test gets its own defaults domain so seeding in one cannot
    /// leak into the next.
    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "FilteredDeckPresetStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func seedsTheStarterPackOnFirstRun() throws {
        withScratchDefaults { defaults in
            let store = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            #expect(store.presets.map(\.name) == FilteredDeckPreset.starterPack.map(\.name))

            // Seeding persists, so a second store sees the same ids rather
            // than a freshly minted second copy.
            let reopened = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            #expect(reopened.presets.map(\.id) == store.presets.map(\.id))
        }
    }

    @Test func doesNotReseedAfterTheUserEmptiesTheList() throws {
        withScratchDefaults { defaults in
            let store = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            for preset in store.presets {
                store.delete(id: preset.id)
            }
            #expect(store.presets.isEmpty)

            let reopened = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            #expect(reopened.presets.isEmpty, "deleting the starters must stick")
        }
    }

    @Test func scopesPresetsPerProfile() throws {
        withScratchDefaults { defaults in
            let first = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            first.add(FilteredDeckPreset(name: "Only In P1", searchQuery: "is:due"))

            let second = FilteredDeckPresetStore(defaults: defaults, profileID: "p2")
            #expect(!second.presets.contains { $0.name == "Only In P1" })
        }
    }

    @Test func roundTripsEveryFieldThroughUserDefaults() throws {
        try withScratchDefaults { defaults in
            let store = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            let preset = FilteredDeckPreset(
                name: "Fragile",
                searchQuery: "prop:ivl<7 is:review",
                limit: 33,
                order: .retrievabilityAscending,
                reschedule: false
            )
            store.add(preset)

            let reopened = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            let restored = try #require(reopened.presets.first { $0.id == preset.id })
            #expect(restored == preset)
        }
    }

    @Test func updateReplacesByIdAndIgnoresAStalePreset() throws {
        withScratchDefaults { defaults in
            let store = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            var preset = FilteredDeckPreset(name: "Leeches", searchQuery: "is:due tag:leech")
            store.add(preset)
            let countAfterAdd = store.presets.count

            preset.limit = 12
            store.update(preset)
            #expect(store.presets.first { $0.id == preset.id }?.limit == 12)

            store.delete(id: preset.id)
            store.update(preset)
            #expect(store.presets.count == countAfterAdd - 1, "updating a deleted preset must not resurrect it")
        }
    }

    @Test func reorderPersistsTheNewOrder() throws {
        try withScratchDefaults { defaults in
            let store = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            try #require(store.presets.count >= 3)
            let originalOrder = store.presets.map(\.id)

            store.reorder(Array(store.presets.reversed()))

            let reopened = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            #expect(reopened.presets.map(\.id) == originalOrder.reversed())
        }
    }

    @Test func reorderRejectsAListThatIsNotAPermutation() throws {
        try withScratchDefaults { defaults in
            let store = FilteredDeckPresetStore(defaults: defaults, profileID: "p1")
            let originalOrder = store.presets.map(\.id)
            try #require(originalOrder.count >= 2)

            store.reorder(Array(store.presets.dropLast()))
            #expect(store.presets.map(\.id) == originalOrder, "a short list must not silently drop a preset")

            store.reorder(store.presets + [FilteredDeckPreset(name: "Smuggled", searchQuery: "is:due")])
            #expect(store.presets.map(\.id) == originalOrder, "reorder is not an add")
        }
    }

    @Test func decodingSurvivesAnUnknownGatherOrder() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"From The Future","searchQuery":"is:due","limit":7,"order":999,"reschedule":true}]
        """
        let decoded = try JSONDecoder().decode([FilteredDeckPreset].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].limit == 7)
        #expect(decoded[0].order == .oldestReviewedFirst, "an unknown order must not take the whole list down")
    }

    @Test func specCarriesThePresetIntoOneSearchTerm() {
        let preset = FilteredDeckPreset(
            name: "Leeches",
            searchQuery: "is:due tag:leech",
            limit: 25,
            order: .lapses,
            reschedule: false
        )
        let spec = preset.spec
        #expect(spec.id == DeckID(0), "a preset always describes a create until the caller resolves a deck")
        #expect(spec.name == "Leeches")
        #expect(spec.reschedule == false)
        #expect(spec.allowEmpty == false)
        #expect(spec.searchTerms == [
            FilteredDeckSearchTerm(search: "is:due tag:leech", limit: 25, order: .lapses)
        ])
    }
}
