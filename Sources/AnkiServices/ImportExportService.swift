//
//  ImportExportService.swift
//  AnkiServices
//
//  Created by Vladimir Gusev on 01.04.2026.
//

import AnkiBackend
import AnkiProtoBridge
public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct ImportExportService: Sendable {
    public var importAnkiPackage: @Sendable (_ path: String) throws -> String
    public var exportCollectionPackage: @Sendable (_ outPath: String, _ includeMedia: Bool) throws -> Void
    public var exportDeckPackage: @Sendable (
        _ deckId: DeckID,
        _ outPath: String,
        _ withScheduling: Bool,
        _ withDeckConfigs: Bool,
        _ withMedia: Bool,
        _ legacy: Bool
    ) throws -> UInt32

    /// Export the entire current collection as an .apkg suitable for the merge
    /// flow (re-importable into another collection). Always includes media,
    /// scheduling, and deck configs.
    public var exportApkgForMerge: @Sendable (_ outPath: String) throws -> Void

    /// Import an .apkg into the current collection using merge-friendly
    /// options (merge notetypes, update notes/notetypes if newer). Returns
    /// the import log summary string.
    public var importApkgForMerge: @Sendable (_ path: String) throws -> String

    /// How a text file to import is laid out, and how the engine would
    /// import it (`Request.csvMetadata`). Each option, when given, replaces
    /// the engine's guess.
    public var csvMetadata: @Sendable (
        _ path: String,
        _ delimiter: CsvImportMetadata.Delimiter?,
        _ notetypeId: NotetypeID?,
        _ deckId: DeckID?,
        _ isHTML: Bool?
    ) throws -> CsvImportMetadata

    /// Imports a text file, one note per line, as `metadata` describes.
    public var importCsv: @Sendable (_ path: String, _ metadata: CsvImportMetadata) throws -> CsvImportSummary
}

extension ImportExportService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            importAnkiPackage: { path in
                let log = try backend.invoke(.importAnkiPackage(path: path))
                return "Imported: \(log.newCount) new, \(log.updatedCount) updated, \(log.duplicateCount) duplicates"
            },
            exportCollectionPackage: { outPath, includeMedia in
                let export = Result { try backend.invoke(.exportCollectionPackage(outPath: outPath, includeMedia: includeMedia)) }
                try backend.reopenCollection()
                try export.get()
            },
            exportDeckPackage: { deckId, outPath, withScheduling, withDeckConfigs, withMedia, legacy in
                try backend.invoke(.exportAnkiPackage(
                    deckId: deckId,
                    outPath: outPath,
                    withScheduling: withScheduling,
                    withDeckConfigs: withDeckConfigs,
                    withMedia: withMedia,
                    legacy: legacy
                ))
            },
            exportApkgForMerge: { outPath in
                try backend.invoke(.exportAnkiPackageForMerge(outPath: outPath))
            },
            importApkgForMerge: { path in
                let log = try backend.invoke(.importAnkiPackageForMerge(path: path))
                return "Merged: \(log.newCount) new, \(log.updatedCount) updated, \(log.duplicateCount) duplicates"
            },
            csvMetadata: { path, delimiter, notetypeId, deckId, isHTML in
                try backend.invoke(.csvMetadata(
                    path: path,
                    delimiter: delimiter,
                    notetypeId: notetypeId,
                    deckId: deckId,
                    isHTML: isHTML
                ))
            },
            importCsv: { path, metadata in
                try backend.invoke(.importCsv(path: path, metadata: metadata))
            }
        )
    }()
}

extension ImportExportService: TestDependencyKey {
    public static let testValue = ImportExportService()
}

extension DependencyValues {
    public var importExportService: ImportExportService {
        get { self[ImportExportService.self] }
        set { self[ImportExportService.self] = newValue }
    }
}
