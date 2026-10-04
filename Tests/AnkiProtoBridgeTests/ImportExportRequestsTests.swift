//
//  ImportExportRequestsTests.swift
//  AnkiProtoBridgeTests
//
//  Created by Vladimir Gusev on 12.05.2026.
//

import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend
import AnkiProto
private import SwiftProtobuf

@Suite struct ImportExportRequestsTests {
    // MARK: - importAnkiPackage

    @Test func importAnkiPackage_dispatches_to_importExport_service() {
        let envelope: Request<ImportLogSummary> = .importAnkiPackage(path: "/tmp/x.apkg")
        #expect(envelope.serviceId == ServiceID.importExport)
        #expect(envelope.methodId == ImportExportMethod.importAnkiPackage)
    }

    @Test func importAnkiPackage_encodes_path() throws {
        let envelope: Request<ImportLogSummary> = .importAnkiPackage(path: "/tmp/deck.apkg")
        let proto = try Anki_ImportExport_ImportAnkiPackageRequest(serializedBytes: envelope.body)
        #expect(proto.packagePath == "/tmp/deck.apkg")
    }

    @Test func importAnkiPackage_decodes_log_counts() throws {
        var note = Anki_ImportExport_ImportResponse.Note()
        note.fields = ["a", "b"]
        var log = Anki_ImportExport_ImportResponse.Log()
        log.new = [note, note, note]
        log.updated = [note]
        log.duplicate = [note, note]
        var resp = Anki_ImportExport_ImportResponse()
        resp.log = log
        let bytes = try resp.serializedData()

        let envelope: Request<ImportLogSummary> = .importAnkiPackage(path: "/x")
        let result = try envelope.decode(bytes)

        #expect(result.newCount == 3)
        #expect(result.updatedCount == 1)
        #expect(result.duplicateCount == 2)
    }

    // MARK: - Text files (CSV, TSV)

    @Test func csvMetadata_dispatches_and_encodes_the_given_choices() throws {
        let envelope: Request<CsvImportMetadata> = .csvMetadata(
            path: "/tmp/cards.tsv", delimiter: .tab, notetypeId: NotetypeID(7), deckId: DeckID(9), isHTML: true
        )
        #expect(envelope.serviceId == ServiceID.importExport)
        #expect(envelope.methodId == ImportExportMethod.getCsvMetadata)
        let proto = try Anki_ImportExport_CsvMetadataRequest(serializedBytes: envelope.body)
        #expect(proto.path == "/tmp/cards.tsv")
        #expect(proto.hasDelimiter)
        #expect(proto.delimiter == .tab)
        #expect(proto.notetypeID == 7)
        #expect(proto.deckID == 9)
        #expect(proto.hasIsHtml)
        #expect(proto.isHtml)
    }

    @Test func csvMetadata_leaves_what_isnt_given_to_the_engine() throws {
        let envelope: Request<CsvImportMetadata> = .csvMetadata(path: "/tmp/cards.csv")
        let proto = try Anki_ImportExport_CsvMetadataRequest(serializedBytes: envelope.body)
        #expect(!proto.hasDelimiter)
        #expect(!proto.hasNotetypeID)
        #expect(!proto.hasDeckID)
        #expect(!proto.hasIsHtml)
    }

    @Test func csvMetadata_decodes_columns_mapping_and_preview() throws {
        var proto = Anki_ImportExport_CsvMetadata()
        proto.delimiter = .comma
        proto.isHtml = true
        proto.columnLabels = ["Front", "Back", "Tags"]
        proto.deckID = 5
        var mapped = Anki_ImportExport_CsvMetadata.MappedNotetype()
        mapped.id = 11
        mapped.fieldColumns = [1, 2]
        proto.globalNotetype = mapped
        proto.tagsColumn = 3
        proto.forceDelimiter = true
        var row = Anki_Generic_StringList()
        row.vals = ["a", "b", "t"]
        proto.preview = [row]
        proto.dupeResolution = .preserve

        let envelope: Request<CsvImportMetadata> = .csvMetadata(path: "/x")
        let metadata = try envelope.decode(try proto.serializedData())

        #expect(metadata.delimiter == .comma)
        #expect(metadata.isHTML)
        #expect(metadata.columnLabels == ["Front", "Back", "Tags"])
        #expect(metadata.deck == .existing(DeckID(5)))
        #expect(metadata.notetype == .global(id: NotetypeID(11), fieldColumns: [1, 2]))
        #expect(metadata.tagsColumn == 3)
        #expect(metadata.forcesDelimiter)
        #expect(!metadata.forcesIsHTML)
        #expect(metadata.preview == [["a", "b", "t"]])
        #expect(metadata.duplicates == .preserve)
        #expect(metadata.columnCount == 3)
    }

    @Test func importCsv_sends_the_choices_back() throws {
        let metadata = CsvImportMetadata(
            delimiter: .tab,
            columnLabels: ["", ""],
            deck: .new("Imported"),
            notetype: .global(id: NotetypeID(3), fieldColumns: [2, 1]),
            duplicates: .duplicate
        )
        let envelope: Request<CsvImportSummary> = .importCsv(path: "/tmp/cards.tsv", metadata: metadata)
        #expect(envelope.serviceId == ServiceID.importExport)
        #expect(envelope.methodId == ImportExportMethod.importCsv)
        let proto = try Anki_ImportExport_ImportCsvRequest(serializedBytes: envelope.body)
        #expect(proto.path == "/tmp/cards.tsv")
        #expect(proto.metadata.deckName == "Imported")
        #expect(proto.metadata.globalNotetype.id == 3)
        #expect(proto.metadata.globalNotetype.fieldColumns == [2, 1])
        #expect(proto.metadata.dupeResolution == .duplicate)
        #expect(CsvMetadataMapping.metadata(proto.metadata) == metadata, "and it reads back as the same choices")
    }

    @Test func importCsv_decodes_every_count() throws {
        var note = Anki_ImportExport_ImportResponse.Note()
        note.fields = ["a"]
        var log = Anki_ImportExport_ImportResponse.Log()
        log.new = [note, note]
        log.updated = [note]
        log.duplicate = [note]
        log.emptyFirstField = [note, note, note]
        log.foundNotes = 7
        var resp = Anki_ImportExport_ImportResponse()
        resp.log = log

        let envelope: Request<CsvImportSummary> = .importCsv(path: "/x", metadata: CsvImportMetadata())
        let summary = try envelope.decode(try resp.serializedData())

        #expect(summary == CsvImportSummary(added: 2, updated: 1, duplicates: 1, emptyFirstField: 3, foundNotes: 7))
    }

    // MARK: - exportCollectionPackage

    @Test func exportCollectionPackage_dispatches_and_sets_fields() throws {
        let envelope: Request<Void> = .exportCollectionPackage(outPath: "/tmp/c.colpkg", includeMedia: true)
        #expect(envelope.serviceId == ServiceID.importExport)
        #expect(envelope.methodId == ImportExportMethod.exportCollectionPackage)
        let proto = try Anki_ImportExport_ExportCollectionPackageRequest(serializedBytes: envelope.body)
        #expect(proto.outPath == "/tmp/c.colpkg")
        #expect(proto.includeMedia)
        #expect(!proto.legacy)
    }

    // MARK: - exportAnkiPackage

    @Test func exportAnkiPackage_dispatches_to_exportAnkiPackage() {
        let envelope: Request<UInt32> = .exportAnkiPackage(
            deckId: DeckID(42), outPath: "/tmp/d.apkg",
            withScheduling: true, withDeckConfigs: false, withMedia: true, legacy: false
        )
        #expect(envelope.serviceId == ServiceID.importExport)
        #expect(envelope.methodId == ImportExportMethod.exportAnkiPackage)
    }

    @Test func exportAnkiPackage_encodes_options_and_limit() throws {
        let envelope: Request<UInt32> = .exportAnkiPackage(
            deckId: DeckID(99), outPath: "/tmp/d.apkg",
            withScheduling: true, withDeckConfigs: true, withMedia: false, legacy: true
        )
        let proto = try Anki_ImportExport_ExportAnkiPackageRequest(serializedBytes: envelope.body)
        #expect(proto.outPath == "/tmp/d.apkg")
        #expect(proto.options.withScheduling)
        #expect(proto.options.withDeckConfigs)
        #expect(!proto.options.withMedia)
        #expect(proto.options.legacy)
        #expect(proto.limit.deckID == 99)
    }

    @Test func exportAnkiPackage_decodes_count() throws {
        var resp = Anki_Generic_UInt32()
        resp.val = 1234
        let bytes = try resp.serializedData()

        let envelope: Request<UInt32> = .exportAnkiPackage(
            deckId: DeckID(1), outPath: "/x",
            withScheduling: false, withDeckConfigs: false, withMedia: false, legacy: false
        )
        #expect(try envelope.decode(bytes) == 1234)
    }
}
