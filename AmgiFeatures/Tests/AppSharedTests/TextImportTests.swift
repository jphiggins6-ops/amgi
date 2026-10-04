//
//  TextImportTests.swift
//  AppSharedTests
//

import Testing
import Foundation
import Dependencies
import AnkiKit
import AnkiClients
import AnkiServices
@testable import AppShared

@MainActor
@Suite struct TextImportTests {
    private static let file = TextImportFile(fileName: "cards.tsv", path: "/tmp/cards.tsv")

    /// Two columns, no names, mapped in order onto a two-field note type.
    nonisolated static let read = CsvImportMetadata(
        delimiter: .tab,
        columnLabels: ["", ""],
        deck: .existing(DeckID(1)),
        notetype: .global(id: NotetypeID(10), fieldColumns: [1, 2]),
        preview: [["The <b>heart</b> pumps blood", "Extra note"], ["Second", "line"]]
    )

    private func makeModel(
        imported: Recorder<CsvImportMetadata> = Recorder(),
        delimiters: Recorder<String> = Recorder()
    ) -> TextImportModel {
        withDependencies {
            $0.importExportService.csvMetadata = { _, delimiter, _, _, _ in
                delimiters.record(delimiter.map { "\($0)" } ?? "guess")
                return Self.read
            }
            $0.importExportService.importCsv = { _, metadata in
                imported.record(metadata)
                return CsvImportSummary(added: 2, foundNotes: 2)
            }
            $0.notetypesClient.listAll = { [NotetypeNameId(id: NotetypeID(10), name: "Cloze")] }
            $0.notetypesClient.get = { _ in
                Notetype(id: NotetypeID(10), name: "Cloze", fields: [Notetype.Field(name: "Text"), Notetype.Field(name: "Back Extra")])
            }
            $0.deckClient.fetchAll = {
                [DeckInfo(id: DeckID(1), name: "Default"), DeckInfo(id: DeckID(2), name: "Study Now", isFiltered: true)]
            }
        } operation: {
            TextImportModel(file: Self.file)
        }
    }

    @Test func aTSVIsReadTabSeparatedWithItsNoteTypesFields() async {
        let delimiters = Recorder<String>()
        let model = makeModel(delimiters: delimiters)
        await model.load()

        #expect(model.phase == .ready)
        #expect(delimiters.all == ["tab"], "a .tsv is read tab-separated, not guessed")
        #expect(model.fieldNames == ["Text", "Back Extra"])
        #expect(model.decks.map(\.name) == ["Default"], "a filtered deck can't take new cards")
        #expect(model.columns.map(\.title) == ["1 · The heart pumps blood", "2 · Extra note"])
    }

    @Test func eachFieldTakesAnyColumnOrNothing() async {
        let model = makeModel()
        await model.load()

        model.chooseColumn(2, forField: 0)
        model.chooseColumn(0, forField: 1)
        #expect(model.metadata.notetype == .global(id: NotetypeID(10), fieldColumns: [2, 0]))
        #expect(model.canImport)

        model.chooseColumn(0, forField: 0)
        #expect(!model.canImport, "no column would fill any field")
    }

    @Test func importingSendsTheChoicesAndSaysWhatHappened() async {
        let imported = Recorder<CsvImportMetadata>()
        let model = makeModel(imported: imported)
        await model.load()

        model.chooseDuplicates(.preserve)
        await model.runImport()

        #expect(model.phase == .finished(CsvImportSummary(added: 2, foundNotes: 2)))
        #expect(imported.all.first?.duplicates == .preserve)
        #expect(imported.all.first?.notetype == .global(id: NotetypeID(10), fieldColumns: [1, 2]))
    }

    @Test func theSummaryReadsAsSentences() {
        #expect(TextImportModel.summaryLines(CsvImportSummary(added: 1)) == ["1 new note"])
        #expect(TextImportModel.summaryLines(CsvImportSummary(added: 3, updated: 2, emptyFirstField: 1)) == [
            "3 new notes",
            "2 notes updated",
            "1 line had an empty first field and was skipped",
        ])
    }

    @Test func htmlIsShownAsPlainText() {
        #expect(TextImportModel.plainText("<div>Left&nbsp;<b>ventricle</b></div>") == "Left ventricle")
        #expect(TextImportModel.previewLine(["a", "<i>b</i>"]) == "a  |  b")
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
