//
//  FilteredDeckPreset.swift
//  AppCore
//

public import Foundation
public import AnkiKit
import Observation

/// A saved shortcut for building a filtered deck: everything the engine
/// needs, minus the deck itself.
///
/// Presets are app shortcuts, not collection data — they never reach the
/// Anki SQLite schema and never sync. The decks they build are ordinary
/// Anki filtered decks and do sync, to desktop Anki and AnkiDroid like
/// any other.
public struct FilteredDeckPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// Doubles as the name of the deck this preset builds, which is what
    /// makes re-running a preset refresh one deck instead of creating a
    /// new one each time.
    public var name: String
    /// Anki search syntax, e.g. `is:due tag:leech`.
    public var searchQuery: String
    public var limit: Int
    public var order: FilteredDeckOrder
    public var reschedule: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        searchQuery: String,
        limit: Int = 100,
        order: FilteredDeckOrder = .oldestReviewedFirst,
        reschedule: Bool = true
    ) {
        self.id = id
        self.name = name
        self.searchQuery = searchQuery
        self.limit = limit
        self.order = order
        self.reschedule = reschedule
    }

    /// What `DeckClient.createFilteredDeck` takes. The id is left at
    /// `DeckID(0)` (create); the caller substitutes an existing filtered
    /// deck's id when one already carries this name.
    public var spec: FilteredDeckSpec {
        FilteredDeckSpec(
            name: name,
            searchTerms: [
                FilteredDeckSearchTerm(search: searchQuery, limit: limit, order: order)
            ],
            reschedule: reschedule
        )
    }
}

extension FilteredDeckPreset {
    public enum CodingKeys: String, CodingKey {
        case id, name, searchQuery, limit, order, reschedule
    }

    /// Hand-decoded so one preset written by a newer build — an `order`
    /// this version has no case for, say — degrades to a default instead
    /// of throwing and taking the user's whole preset list with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        searchQuery = try container.decodeIfPresent(String.self, forKey: .searchQuery) ?? ""
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 100
        order = (try? container.decode(FilteredDeckOrder.self, forKey: .order)) ?? .oldestReviewedFirst
        reschedule = try container.decodeIfPresent(Bool.self, forKey: .reschedule) ?? true
    }
}

extension FilteredDeckPreset {
    /// Seeded into an empty store the first time a profile opens the
    /// screen, so it opens on something runnable rather than on a blank
    /// list. Deliberately excludes a per-deck cram preset — it would need
    /// a deck name this code cannot guess, and a preset that fails on
    /// first tap is worse than one that isn't there.
    public static var starterPack: [FilteredDeckPreset] {
        [
            FilteredDeckPreset(
                name: "Leeches",
                searchQuery: "is:due tag:leech",
                limit: 50,
                order: .oldestReviewedFirst
            ),
            FilteredDeckPreset(
                name: "Recently Added",
                searchQuery: "added:1 -is:suspended",
                limit: 50,
                order: .added
            ),
            FilteredDeckPreset(
                name: "Fragile Reviews",
                searchQuery: "prop:ivl<7 is:review",
                limit: 50,
                order: .intervalsAscending
            ),
        ]
    }
}

/// Per-profile preset registry, stored as a JSON array in
/// `UserDefaults`. Profile-scoped for the same reason the deck list is:
/// a preset names a deck, and deck names belong to one collection.
///
/// Not a singleton, unlike `AccountStore`. The scope is resolved once at
/// init, so a shared instance would keep serving the old profile's
/// presets after a switch; the root view re-ids on `selectedID`, so a
/// view-owned store is rebuilt against the new profile for free.
@MainActor
@Observable
public final class FilteredDeckPresetStore {
    public private(set) var presets: [FilteredDeckPreset]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let seededKey: String

    public init(
        defaults: UserDefaults = .standard,
        profileID: String = ProfileScope.current()
    ) {
        self.defaults = defaults
        self.storageKey = "amgi.filteredDeckPresets.\(profileID)"
        self.seededKey = "amgi.filteredDeckPresets.seeded.\(profileID)"

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([FilteredDeckPreset].self, from: data) {
            presets = decoded
        } else if defaults.bool(forKey: seededKey) {
            // Seeded once and since emptied. Re-seeding here would make
            // deleting the starters impossible.
            presets = []
        } else {
            // Written out inline rather than through `persist()`: nothing
            // should call an instance method off a half-built `self`.
            let starters = FilteredDeckPreset.starterPack
            presets = starters
            if let data = try? JSONEncoder().encode(starters) {
                defaults.set(data, forKey: storageKey)
            }
            defaults.set(true, forKey: seededKey)
        }
    }

    public func add(_ preset: FilteredDeckPreset) {
        presets.append(preset)
        persist()
    }

    /// Replaces the preset carrying the same id. A no-op when it is gone,
    /// which is what an editor sheet racing a delete should do.
    public func update(_ preset: FilteredDeckPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist()
    }

    public func delete(id: FilteredDeckPreset.ID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    /// Accepts a reordering of the presets already held, and nothing
    /// else. The offset arithmetic behind a drag is SwiftUI's
    /// (`move(fromOffsets:toOffset:)`), which this module deliberately
    /// cannot reach — so the view does the move on a copy and hands the
    /// result back, and this guards against a copy that drifted.
    public func reorder(_ reordered: [FilteredDeckPreset]) {
        guard Set(reordered.map(\.id)) == Set(presets.map(\.id)),
              reordered.count == presets.count
        else { return }
        presets = reordered
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
