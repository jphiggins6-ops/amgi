//
//  FilteredDeckTypes.swift
//  AnkiKit
//

package import Foundation

/// Gather order for one search term of a filtered deck. Raw values are
/// the wire values of `anki.decks.Deck.Filtered.SearchTerm.Order`;
/// `AnkiProtoBridge` owns the conversion so nothing above it ever names
/// an `Anki_*` symbol.
public enum FilteredDeckOrder: Int32, CaseIterable, Codable, Sendable, Identifiable {
    case oldestReviewedFirst = 0
    case random = 1
    case intervalsAscending = 2
    case intervalsDescending = 3
    case lapses = 4
    case added = 5
    case due = 6
    case reverseAdded = 7
    case retrievabilityAscending = 8
    case retrievabilityDescending = 9
    case relativeOverdueness = 10

    public var id: Int32 { rawValue }
}

/// One clause of a filtered deck: an Anki search, how many cards it may
/// gather, and in what order.
public struct FilteredDeckSearchTerm: Equatable, Codable, Sendable {
    public var search: String
    public var limit: Int
    public var order: FilteredDeckOrder

    public init(
        search: String,
        limit: Int = 100,
        order: FilteredDeckOrder = .oldestReviewedFirst
    ) {
        self.search = search
        self.limit = limit
        self.order = order
    }
}

/// Server-prepared filtered deck returned by
/// `Request.filteredDeckTemplate(for:)`. Carries the backend's own
/// defaults opaquely — preview delays, the v1 `delays` list, the fields
/// no Swift mirror models — so `Request.addOrUpdateFilteredDeck(...)`
/// can override the handful we do model instead of reconstructing a
/// whole `FilteredDeckForUpdate` and silently dropping the rest.
public struct FilteredDeckTemplate: Sendable {
    package let bytes: Data
    package init(bytes: Data) { self.bytes = bytes }
}

/// What the caller wants a filtered deck to be. Paired with a
/// `FilteredDeckTemplate` by `DecksService.createFilteredDeck`.
public struct FilteredDeckSpec: Equatable, Sendable {
    /// `DeckID(0)` creates a new deck. Any other id updates *that*
    /// filtered deck in place (which also rebuilds it), so re-running the
    /// same preset refreshes one deck instead of piling up `Leeches`,
    /// `Leeches+`, `Leeches++`.
    public var id: DeckID
    public var name: String
    public var searchTerms: [FilteredDeckSearchTerm]
    /// When true the cards keep their real scheduling; when false the
    /// deck is a preview and answers are discarded on empty.
    public var reschedule: Bool
    /// Anki refuses to build a filtered deck that gathered nothing unless
    /// this is set. Left `false` so "no cards matched" surfaces as an
    /// error the UI can show rather than as an empty deck.
    public var allowEmpty: Bool

    public init(
        id: DeckID = DeckID(0),
        name: String,
        searchTerms: [FilteredDeckSearchTerm],
        reschedule: Bool = true,
        allowEmpty: Bool = false
    ) {
        self.id = id
        self.name = name
        self.searchTerms = searchTerms
        self.reschedule = reschedule
        self.allowEmpty = allowEmpty
    }
}
