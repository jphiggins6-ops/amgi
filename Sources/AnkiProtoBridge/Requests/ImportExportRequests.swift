//
//  ImportExportRequests.swift
//  AnkiProtoBridge
//
//  Created by Vladimir Gusev on 12.05.2026.
//

import Foundation
public import AnkiBackend
public import AnkiKit
import AnkiProto
import SwiftProtobuf

// MARK: - importAnkiPackage

extension Request where Response == ImportLogSummary {
    /// Imports an .apkg at `path` and returns a summary of how many
    /// notes were created, updated, and skipped as duplicates.
    public static func importAnkiPackage(path: String) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ImportAnkiPackageRequest()
                proto.packagePath = path
                return try proto.serializedData()
            },
            decode: { bytes in
                let resp = try Anki_ImportExport_ImportResponse(serializedBytes: bytes)
                return ImportLogSummary(
                    newCount: resp.log.new.count,
                    updatedCount: resp.log.updated.count,
                    duplicateCount: resp.log.duplicate.count
                )
            }
        )
    }
}

// MARK: - importAnkiPackageForMerge

extension Request where Response == ImportLogSummary {
    /// Imports an .apkg using merge-friendly options: notetypes are merged
    /// and notes/notetypes update when the incoming copy is newer. Used by
    /// the sync merge flow to fold a local backup into a freshly-downloaded
    /// server collection.
    public static func importAnkiPackageForMerge(path: String) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ImportAnkiPackageRequest()
                proto.packagePath = path

                var options = Anki_ImportExport_ImportAnkiPackageOptions()
                options.mergeNotetypes = true
                options.withScheduling = true
                options.withDeckConfigs = true
                options.updateNotes = .ifNewer
                options.updateNotetypes = .ifNewer
                proto.options = options

                return try proto.serializedData()
            },
            decode: { bytes in
                let resp = try Anki_ImportExport_ImportResponse(serializedBytes: bytes)
                return ImportLogSummary(
                    newCount: resp.log.new.count,
                    updatedCount: resp.log.updated.count,
                    duplicateCount: resp.log.duplicate.count
                )
            }
        )
    }
}

// MARK: - exportAnkiPackageForMerge (whole collection)

extension Request where Response == Void {
    /// Exports the entire collection as an .apkg suitable for the sync merge
    /// flow (re-importable into another collection). Always includes media,
    /// scheduling, and deck configs.
    public static func exportAnkiPackageForMerge(outPath: String) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ExportAnkiPackageRequest()
                proto.outPath = outPath

                var options = Anki_ImportExport_ExportAnkiPackageOptions()
                options.withScheduling = true
                options.withDeckConfigs = true
                options.withMedia = true
                options.legacy = false
                proto.options = options

                var limit = Anki_ImportExport_ExportLimit()
                limit.limit = .wholeCollection(Anki_Generic_Empty())
                proto.limit = limit

                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }
}

// MARK: - exportCollectionPackage

extension Request where Response == Void {
    /// Writes a full collection .colpkg to `outPath`. `includeMedia`
    /// controls whether media files are bundled.
    public static func exportCollectionPackage(outPath: String, includeMedia: Bool) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportCollectionPackage,
            encode: {
                var proto = Anki_ImportExport_ExportCollectionPackageRequest()
                proto.outPath = outPath
                proto.includeMedia = includeMedia
                proto.legacy = false
                return try proto.serializedData()
            },
            decode: { _ in () }
        )
    }
}

// MARK: - exportAnkiPackage (single deck)

extension Request where Response == UInt32 {
    /// Exports a single deck to an .apkg at `outPath`. Returns the
    /// number of notes exported. `legacy: true` produces an old-format
    /// package compatible with Anki <2.1.50.
    public static func exportAnkiPackage(
        deckId: DeckID,
        outPath: String,
        withScheduling: Bool,
        withDeckConfigs: Bool,
        withMedia: Bool,
        legacy: Bool
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.exportAnkiPackage,
            encode: {
                var proto = Anki_ImportExport_ExportAnkiPackageRequest()
                proto.outPath = outPath

                var options = Anki_ImportExport_ExportAnkiPackageOptions()
                options.withScheduling = withScheduling
                options.withDeckConfigs = withDeckConfigs
                options.withMedia = withMedia
                options.legacy = legacy
                proto.options = options

                var limit = Anki_ImportExport_ExportLimit()
                limit.deckID = deckId.rawValue
                proto.limit = limit

                return try proto.serializedData()
            },
            decode: { bytes in
                let resp = try Anki_Generic_UInt32(serializedBytes: bytes)
                return resp.val
            }
        )
    }
}

// MARK: - Text files (CSV, TSV)

extension Request where Response == CsvImportMetadata {
    /// Reads how a text file to import is laid out: its delimiter (guessed
    /// unless given), columns and first lines, and the deck, note type and
    /// field mapping an import would use. `notetypeId` asks for that note
    /// type's mapping instead of the engine's choice.
    public static func csvMetadata(
        path: String,
        delimiter: CsvImportMetadata.Delimiter? = nil,
        notetypeId: NotetypeID? = nil,
        deckId: DeckID? = nil,
        isHTML: Bool? = nil
    ) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.getCsvMetadata,
            encode: {
                var proto = Anki_ImportExport_CsvMetadataRequest()
                proto.path = path
                if let delimiter { proto.delimiter = CsvMetadataMapping.proto(delimiter) }
                if let notetypeId { proto.notetypeID = notetypeId.rawValue }
                if let deckId { proto.deckID = deckId.rawValue }
                if let isHTML { proto.isHtml = isHTML }
                return try proto.serializedData()
            },
            decode: { bytes in
                CsvMetadataMapping.metadata(try Anki_ImportExport_CsvMetadata(serializedBytes: bytes))
            }
        )
    }
}

extension Request where Response == CsvImportSummary {
    /// Imports a text file, one note per line, as `metadata` describes.
    public static func importCsv(path: String, metadata: CsvImportMetadata) -> Self {
        Self(
            serviceId: ServiceID.importExport,
            methodId: ImportExportMethod.importCsv,
            encode: {
                var proto = Anki_ImportExport_ImportCsvRequest()
                proto.path = path
                proto.metadata = CsvMetadataMapping.proto(metadata)
                return try proto.serializedData()
            },
            decode: { bytes in
                let log = try Anki_ImportExport_ImportResponse(serializedBytes: bytes).log
                return CsvImportSummary(
                    added: log.new.count,
                    updated: log.updated.count,
                    duplicates: log.duplicate.count,
                    conflicting: log.conflicting.count,
                    firstFieldMatch: log.firstFieldMatch.count,
                    missingNotetype: log.missingNotetype.count,
                    missingDeck: log.missingDeck.count,
                    emptyFirstField: log.emptyFirstField.count,
                    foundNotes: Int(log.foundNotes)
                )
            }
        )
    }
}

/// Between the engine's CSV metadata and AnkiKit's mirror of it.
enum CsvMetadataMapping {
    static func metadata(_ proto: Anki_ImportExport_CsvMetadata) -> CsvImportMetadata {
        let deck: CsvImportMetadata.DeckSource? = switch proto.deck {
        case .deckID(let id)?: .existing(DeckID(id))
        case .deckColumn(let column)?: .column(Int(column))
        case .deckName(let name)?: .new(name)
        case nil: nil
        }
        let notetype: CsvImportMetadata.NotetypeSource? = switch proto.notetype {
        case .globalNotetype(let mapped)?:
            .global(id: NotetypeID(mapped.id), fieldColumns: mapped.fieldColumns.map { Int($0) })
        case .notetypeColumn(let column)?: .column(Int(column))
        case nil: nil
        }
        return CsvImportMetadata(
            delimiter: delimiter(proto.delimiter),
            isHTML: proto.isHtml,
            globalTags: proto.globalTags,
            updatedTags: proto.updatedTags,
            columnLabels: proto.columnLabels,
            deck: deck,
            notetype: notetype,
            tagsColumn: Int(proto.tagsColumn),
            guidColumn: Int(proto.guidColumn),
            forcesDelimiter: proto.forceDelimiter,
            forcesIsHTML: proto.forceIsHtml,
            preview: proto.preview.map(\.vals),
            duplicates: CsvImportMetadata.Duplicates(rawValue: proto.dupeResolution.rawValue) ?? .update,
            matchScope: CsvImportMetadata.MatchScope(rawValue: proto.matchScope.rawValue) ?? .notetype
        )
    }

    static func proto(_ metadata: CsvImportMetadata) -> Anki_ImportExport_CsvMetadata {
        var proto = Anki_ImportExport_CsvMetadata()
        proto.delimiter = Self.proto(metadata.delimiter)
        proto.isHtml = metadata.isHTML
        proto.globalTags = metadata.globalTags
        proto.updatedTags = metadata.updatedTags
        proto.columnLabels = metadata.columnLabels
        switch metadata.deck {
        case .existing(let id)?: proto.deckID = id.rawValue
        case .column(let column)?: proto.deckColumn = UInt32(clamping: column)
        case .new(let name)?: proto.deckName = name
        case nil: break
        }
        switch metadata.notetype {
        case .global(let id, let fieldColumns)?:
            var mapped = Anki_ImportExport_CsvMetadata.MappedNotetype()
            mapped.id = id.rawValue
            mapped.fieldColumns = fieldColumns.map { UInt32(clamping: $0) }
            proto.globalNotetype = mapped
        case .column(let column)?: proto.notetypeColumn = UInt32(clamping: column)
        case nil: break
        }
        proto.tagsColumn = UInt32(clamping: metadata.tagsColumn)
        proto.guidColumn = UInt32(clamping: metadata.guidColumn)
        proto.forceDelimiter = metadata.forcesDelimiter
        proto.forceIsHtml = metadata.forcesIsHTML
        proto.preview = metadata.preview.map { row in
            var list = Anki_Generic_StringList()
            list.vals = row
            return list
        }
        proto.dupeResolution = Anki_ImportExport_CsvMetadata.DupeResolution(rawValue: metadata.duplicates.rawValue) ?? .update
        proto.matchScope = Anki_ImportExport_CsvMetadata.MatchScope(rawValue: metadata.matchScope.rawValue) ?? .notetype
        return proto
    }

    static func delimiter(_ proto: Anki_ImportExport_CsvMetadata.Delimiter) -> CsvImportMetadata.Delimiter {
        CsvImportMetadata.Delimiter(rawValue: proto.rawValue) ?? .tab
    }

    static func proto(_ delimiter: CsvImportMetadata.Delimiter) -> Anki_ImportExport_CsvMetadata.Delimiter {
        Anki_ImportExport_CsvMetadata.Delimiter(rawValue: delimiter.rawValue) ?? .tab
    }
}
