//
//  CsvImportTypes.swift
//  AnkiKit
//

/// What the engine makes of a text file to import with one note per line
/// (Anki's CSV and TSV import), mirrored from
/// `Anki_ImportExport_CsvMetadata`. It's shown to be adjusted, then handed
/// back to import with.
public struct CsvImportMetadata: Sendable, Equatable {
    public enum Delimiter: Int, Sendable, CaseIterable, Hashable {
        case tab = 0
        case pipe = 1
        case semicolon = 2
        case colon = 3
        case comma = 4
        case space = 5
    }

    /// What happens to a line whose note is already in the collection.
    public enum Duplicates: Int, Sendable, CaseIterable, Hashable {
        /// The existing note takes the line's fields.
        case update = 0
        /// The existing note is left as it is.
        case preserve = 1
        /// A second note is added.
        case duplicate = 2
    }

    /// Where duplicates are looked for.
    public enum MatchScope: Int, Sendable, Hashable {
        case notetype = 0
        case notetypeAndDeck = 1
    }

    /// Where each line's deck comes from.
    public enum DeckSource: Sendable, Equatable {
        case existing(DeckID)
        /// A one-based column of deck names.
        case column(Int)
        /// A deck to create, by name.
        case new(String)
    }

    /// Where each line's note type comes from.
    public enum NotetypeSource: Sendable, Equatable {
        /// One note type for every line. `fieldColumns[i]` is the one-based
        /// column that fills its field `i`, 0 for none.
        case global(id: NotetypeID, fieldColumns: [Int])
        /// A one-based column naming each line's note type.
        case column(Int)
    }

    public var delimiter: Delimiter
    public var isHTML: Bool
    public var globalTags: [String]
    public var updatedTags: [String]
    /// The file's column names, or empty strings: one per column.
    public var columnLabels: [String]
    public var deck: DeckSource?
    public var notetype: NotetypeSource?
    /// One-based; 0 for none.
    public var tagsColumn: Int
    /// One-based; 0 for none.
    public var guidColumn: Int
    /// Set by the file itself (`#separator:`, `#html:`), so not to be changed.
    public var forcesDelimiter: Bool
    public var forcesIsHTML: Bool
    /// The first few lines, split into columns.
    public var preview: [[String]]
    public var duplicates: Duplicates
    public var matchScope: MatchScope

    public init(
        delimiter: Delimiter = .tab,
        isHTML: Bool = false,
        globalTags: [String] = [],
        updatedTags: [String] = [],
        columnLabels: [String] = [],
        deck: DeckSource? = nil,
        notetype: NotetypeSource? = nil,
        tagsColumn: Int = 0,
        guidColumn: Int = 0,
        forcesDelimiter: Bool = false,
        forcesIsHTML: Bool = false,
        preview: [[String]] = [],
        duplicates: Duplicates = .update,
        matchScope: MatchScope = .notetype
    ) {
        self.delimiter = delimiter
        self.isHTML = isHTML
        self.globalTags = globalTags
        self.updatedTags = updatedTags
        self.columnLabels = columnLabels
        self.deck = deck
        self.notetype = notetype
        self.tagsColumn = tagsColumn
        self.guidColumn = guidColumn
        self.forcesDelimiter = forcesDelimiter
        self.forcesIsHTML = forcesIsHTML
        self.preview = preview
        self.duplicates = duplicates
        self.matchScope = matchScope
    }

    /// How many columns the file has.
    public var columnCount: Int {
        max(columnLabels.count, preview.map(\.count).max() ?? 0)
    }
}

/// What a text-file import did, mirrored from `ImportResponse.Log`.
public struct CsvImportSummary: Sendable, Equatable {
    public var added: Int
    public var updated: Int
    /// Lines whose note was already there, kept or added again as asked.
    public var duplicates: Int
    public var conflicting: Int
    public var firstFieldMatch: Int
    public var missingNotetype: Int
    public var missingDeck: Int
    public var emptyFirstField: Int
    /// Lines read from the file.
    public var foundNotes: Int

    public init(
        added: Int = 0,
        updated: Int = 0,
        duplicates: Int = 0,
        conflicting: Int = 0,
        firstFieldMatch: Int = 0,
        missingNotetype: Int = 0,
        missingDeck: Int = 0,
        emptyFirstField: Int = 0,
        foundNotes: Int = 0
    ) {
        self.added = added
        self.updated = updated
        self.duplicates = duplicates
        self.conflicting = conflicting
        self.firstFieldMatch = firstFieldMatch
        self.missingNotetype = missingNotetype
        self.missingDeck = missingDeck
        self.emptyFirstField = emptyFirstField
        self.foundNotes = foundNotes
    }
}
