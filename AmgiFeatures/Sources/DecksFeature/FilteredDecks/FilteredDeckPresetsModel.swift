//
//  FilteredDeckPresetsModel.swift
//  DecksFeature
//

import AnkiClients
import AnkiKit
import AppCore
import AppShared
import Dependencies
import Foundation
import Observation

/// What one preset did in a Quick Create run. Kept per preset rather
/// than collapsed into a single alert: building five decks where the
/// third matched nothing is a partial success, and saying only "failed"
/// hides the four decks that are now sitting in the library.
struct FilteredDeckBuildResult: Identifiable, Equatable {
    enum Outcome: Equatable {
        case built(cardCount: Int)
        case failed(String)
    }

    /// The preset's id, so rows can line results up with their preset.
    let id: UUID
    let name: String
    let outcome: Outcome
}

/// Selection + build logic for the filtered-deck presets screen. The
/// View owns navigation and the editor sheet; this owns the store, the
/// engine calls, and the per-preset outcome assembly, which is the part
/// worth testing without a backend.
@Observable
@MainActor
final class FilteredDeckPresetsModel {
    let store: FilteredDeckPresetStore
    var selection: Set<UUID>
    private(set) var isBuilding = false
    private(set) var results: [FilteredDeckBuildResult] = []

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.collectionStore) private var collectionStore

    init(store: FilteredDeckPresetStore = FilteredDeckPresetStore()) {
        self.store = store
        self.selection = Set(store.presets.map(\.id))
    }

    var selectedPresets: [FilteredDeckPreset] {
        store.presets.filter { selection.contains($0.id) }
    }

    func toggle(_ preset: FilteredDeckPreset) {
        if selection.contains(preset.id) {
            selection.remove(preset.id)
        } else {
            selection.insert(preset.id)
        }
    }

    func forget(id: FilteredDeckPreset.ID) {
        selection.remove(id)
        results.removeAll { $0.id == id }
        store.delete(id: id)
    }

    /// Builds every selected preset, in list order.
    ///
    /// One deck tree read up front resolves each preset's name to an
    /// existing filtered deck where there is one, so the second tap
    /// refreshes `Leeches` rather than adding `Leeches+` next to it. One
    /// more read afterwards picks up the gathered counts, which only
    /// exist on the rebuilt tree.
    func build() async {
        let targets = selectedPresets
        guard !targets.isEmpty, !isBuilding else { return }

        isBuilding = true
        results = []
        defer { isBuilding = false }

        let existing = Self.filteredDecksByName((try? await deckClient.fetchTree()) ?? [])

        var succeeded: [(presetID: UUID, name: String, deckID: DeckID)] = []
        var outcomes: [UUID: FilteredDeckBuildResult] = [:]
        var changes = CollectionChanges()

        for preset in targets {
            var spec = preset.spec
            spec.id = existing[preset.name]?.id ?? DeckID(0)
            do {
                let creation = try await deckClient.createFilteredDeck(spec)
                changes = changes.union(creation.changes)
                succeeded.append((preset.id, preset.name, creation.id))
            } catch {
                Log.decks.error("Filtered deck build failed for '\(preset.name)': \(error)")
                outcomes[preset.id] = FilteredDeckBuildResult(
                    id: preset.id,
                    name: preset.name,
                    outcome: .failed(error.localizedDescription)
                )
            }
        }

        collectionStore.apply(changes)

        let counts = Self.countsByDeck((try? await deckClient.fetchTree()) ?? [])
        for entry in succeeded {
            outcomes[entry.presetID] = FilteredDeckBuildResult(
                id: entry.presetID,
                name: entry.name,
                outcome: .built(cardCount: counts[entry.deckID]?.total ?? 0)
            )
        }

        results = targets.compactMap { outcomes[$0.id] }
    }

    /// Filtered decks keyed by the full `Parent::Child` name, which is
    /// what a preset's name is compared against. Duplicates keep the
    /// first — the engine forbids two decks with one name, so a second
    /// hit only ever means a tree read raced a rename.
    static func filteredDecksByName(_ tree: [DeckTreeNode]) -> [String: DeckInfo] {
        Dictionary(
            tree.flattened().filter(\.isFiltered).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func countsByDeck(_ tree: [DeckTreeNode]) -> [DeckID: DeckCounts] {
        Dictionary(
            tree.flattened().map { ($0.id, $0.counts) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
