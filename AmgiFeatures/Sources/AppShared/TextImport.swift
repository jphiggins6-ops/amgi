//
//  TextImport.swift
//  AppShared
//
//  Importing notes from a text file, one note per line: TSV, CSV or plain
//  text, as Anki's File → Import does. The engine reads the file's layout
//  (`ImportExportService.csvMetadata`), the sheet lets the deck, note type
//  and the column for each field be changed, and the engine imports it.
//

import OSLog
import SwiftUI
import AppCore
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Foundation
import Theme

/// A text file picked for import, copied to where the engine can read it.
struct TextImportFile: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let path: String

    /// The kinds of file imported as text, one note per line.
    static let extensions: Set<String> = ["tsv", "txt", "csv"]

    static func copy(from url: URL) throws -> TextImportFile {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return TextImportFile(fileName: url.lastPathComponent, path: copy.path)
    }

    /// Deletes the copy.
    func remove() {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    /// A .tsv is tab-separated; for anything else the engine works it out.
    var initialDelimiter: CsvImportMetadata.Delimiter? {
        URL(fileURLWithPath: fileName).pathExtension.lowercased() == "tsv" ? .tab : nil
    }
}

/// One column of the file, as the pickers list it.
struct TextImportColumn: Identifiable, Equatable {
    /// One-based, as the engine counts columns.
    let number: Int
    let title: String

    var id: Int { number }
}

@Observable
@MainActor
final class TextImportModel {
    enum Phase: Equatable {
        case loading
        case ready
        case importing
        case finished(CsvImportSummary)
        case failed(String)
    }

    let file: TextImportFile
    private(set) var phase: Phase = .loading
    private(set) var metadata = CsvImportMetadata()
    private(set) var notetypes: [NotetypeNameId] = []
    /// Decks to import into; filtered decks can't hold new cards.
    private(set) var decks: [DeckInfo] = []
    /// The chosen note type's fields, in order.
    private(set) var fieldNames: [String] = []
    /// The deck the file names itself, a new one or a column of names, kept
    /// so it can be chosen again after picking an existing deck.
    private(set) var fileDeck: CsvImportMetadata.DeckSource?
    /// Why the last change couldn't be made.
    var errorMessage: String?

    @ObservationIgnored @Dependency(\.importExportService) private var importExportService
    @ObservationIgnored @Dependency(\.notetypesClient) private var notetypesClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient

    init(file: TextImportFile) {
        self.file = file
    }

    func load() async {
        do {
            notetypes = try await notetypesClient.listAll()
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            decks = try await deckClient.fetchAll()
                .filter { !$0.isFiltered }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try await read(delimiter: file.initialDelimiter, notetypeId: nil, isHTML: nil)
            switch metadata.deck {
            case .new?, .column?: fileDeck = metadata.deck
            default: fileDeck = nil
            }
            phase = .ready
        } catch {
            Log.decks.error("Reading \(self.file.fileName) failed: \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Choices

    var chosenNotetypeId: NotetypeID? {
        if case .global(let id, _)? = metadata.notetype { return id }
        return nil
    }

    var chosenDeckId: DeckID? {
        if case .existing(let id)? = metadata.deck { return id }
        return nil
    }

    /// A different note type: the engine maps the columns to its fields.
    func chooseNotetype(_ id: NotetypeID) async {
        guard id != chosenNotetypeId else { return }
        await reread(delimiter: metadata.delimiter, notetypeId: id)
    }

    /// A different separator splits the lines into different columns.
    func chooseDelimiter(_ delimiter: CsvImportMetadata.Delimiter) async {
        guard delimiter != metadata.delimiter else { return }
        await reread(delimiter: delimiter, notetypeId: chosenNotetypeId)
    }

    /// An existing deck, or nil for the deck the file names itself.
    func chooseDeck(_ id: DeckID?) {
        metadata.deck = id.map { CsvImportMetadata.DeckSource.existing($0) } ?? fileDeck
    }

    func column(forField index: Int) -> Int {
        guard case .global(_, let columns)? = metadata.notetype, columns.indices.contains(index) else { return 0 }
        return columns[index]
    }

    /// `column` (one-based, 0 for nothing) fills field `index`.
    func chooseColumn(_ column: Int, forField index: Int) {
        guard case .global(let id, var columns)? = metadata.notetype, index >= 0 else { return }
        while columns.count <= index { columns.append(0) }
        columns[index] = column
        metadata.notetype = .global(id: id, fieldColumns: columns)
    }

    func chooseTagsColumn(_ column: Int) {
        metadata.tagsColumn = column
    }

    func chooseDuplicates(_ duplicates: CsvImportMetadata.Duplicates) {
        metadata.duplicates = duplicates
    }

    func setHTML(_ isHTML: Bool) {
        metadata.isHTML = isHTML
    }

    /// Something to import: a column for at least one field, or note types
    /// named line by line.
    var canImport: Bool {
        switch metadata.notetype {
        case .global(_, let columns)?: columns.contains { $0 > 0 }
        case .column?: true
        case nil: false
        }
    }

    var columns: [TextImportColumn] {
        Self.columns(of: metadata)
    }

    // MARK: - Importing

    func runImport() async {
        guard phase == .ready, canImport else { return }
        phase = .importing
        let service = importExportService
        let path = file.path
        let metadata = self.metadata
        do {
            let summary = try await backendOffload { try service.importCsv(path, metadata) }
            phase = .finished(summary)
        } catch {
            Log.decks.error("Importing \(self.file.fileName) failed: \(error)")
            phase = .ready
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Reading the file

    private func reread(delimiter: CsvImportMetadata.Delimiter?, notetypeId: NotetypeID?) async {
        let kept = metadata
        do {
            try await read(delimiter: delimiter, notetypeId: notetypeId, isHTML: kept.isHTML)
            // What was chosen here stays chosen; the tags column too, while
            // the columns are the same ones.
            metadata.duplicates = kept.duplicates
            if kept.deck != nil { metadata.deck = kept.deck }
            if kept.delimiter == metadata.delimiter { metadata.tagsColumn = kept.tagsColumn }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func read(
        delimiter: CsvImportMetadata.Delimiter?,
        notetypeId: NotetypeID?,
        isHTML: Bool?
    ) async throws {
        let service = importExportService
        let path = file.path
        let deckId = chosenDeckId
        let layout = try await backendOffload {
            try service.csvMetadata(path, delimiter, notetypeId, deckId, isHTML)
        }
        if case .global(let id, _)? = layout.notetype {
            fieldNames = try await notetypesClient.get(id).fields.map(\.name)
        } else {
            fieldNames = []
        }
        metadata = layout
    }

    // MARK: - Text

    /// "1 · Front", or the column's text on the first line when the file
    /// doesn't name its columns.
    static func columns(of metadata: CsvImportMetadata) -> [TextImportColumn] {
        (0..<metadata.columnCount).map { index in
            let label = metadata.columnLabels.indices.contains(index) ? metadata.columnLabels[index] : ""
            let firstLine = metadata.preview.first ?? []
            let sample = firstLine.indices.contains(index) ? firstLine[index] : ""
            let text = plainText(label.isEmpty ? sample : label)
            let short = text.count > 32 ? String(text.prefix(32)) + "…" : text
            return TextImportColumn(number: index + 1, title: short.isEmpty ? "Column \(index + 1)" : "\(index + 1) · \(short)")
        }
    }

    /// A line of the file as a row of the preview.
    static func previewLine(_ row: [String]) -> String {
        row.map { plainText($0) }.joined(separator: "  |  ")
    }

    /// HTML as one line of plain text.
    static func plainText(_ html: String) -> String {
        var text = ""
        var inTag = false
        for character in html {
            if character == "<" {
                inTag = true
            } else if character == ">" && inTag {
                inTag = false
                text.append(" ")
            } else if !inTag {
                text.append(character)
            }
        }
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func title(_ delimiter: CsvImportMetadata.Delimiter) -> String {
        switch delimiter {
        case .tab: "Tab"
        case .pipe: "Pipe |"
        case .semicolon: "Semicolon ;"
        case .colon: "Colon :"
        case .comma: "Comma ,"
        case .space: "Space"
        }
    }

    /// What the import did, a line each.
    static func summaryLines(_ summary: CsvImportSummary) -> [String] {
        var lines = [count(summary.added, "new note", "new notes")]
        if summary.updated > 0 { lines.append(count(summary.updated, "note updated", "notes updated")) }
        if summary.duplicates > 0 {
            lines.append(count(summary.duplicates, "note was already there", "notes were already there"))
        }
        if summary.firstFieldMatch > 0 {
            lines.append(count(summary.firstFieldMatch, "matched an existing note by its first field", "matched existing notes by their first field"))
        }
        if summary.conflicting > 0 {
            lines.append(count(summary.conflicting, "line conflicted with an existing note and was skipped", "lines conflicted with existing notes and were skipped"))
        }
        if summary.emptyFirstField > 0 {
            lines.append(count(summary.emptyFirstField, "line had an empty first field and was skipped", "lines had an empty first field and were skipped"))
        }
        if summary.missingNotetype > 0 {
            lines.append(count(summary.missingNotetype, "line named a note type that doesn't exist", "lines named a note type that doesn't exist"))
        }
        if summary.missingDeck > 0 {
            lines.append(count(summary.missingDeck, "line named a deck that doesn't exist", "lines named a deck that doesn't exist"))
        }
        return lines
    }

    private static func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number) \(number == 1 ? one : many)"
    }
}

// MARK: - The sheet

/// Choosing how a text file becomes notes, then importing it.
struct TextImportSheet: View {
    @State private var model: TextImportModel
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    init(file: TextImportFile, onImported: @escaping () -> Void) {
        _model = State(initialValue: TextImportModel(file: file))
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import Text File")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(model.phase == .importing)
        .task { await model.load() }
        .onChange(of: model.phase) { _, phase in
            if case .finished = phase { onImported() }
        }
        .onDisappear { model.file.remove() }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Read the File", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .ready, .importing:
            form
        case .finished(let summary):
            finished(summary)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if case .finished = model.phase {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(model.phase == .importing)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    Task { await model.runImport() }
                }
                .disabled(model.phase != .ready || !model.canImport)
            }
        }
    }

    // MARK: Form

    private var form: some View {
        Form {
            fileSection
            Section("Columns") {
                Picker("Separated by", selection: delimiterBinding) {
                    ForEach(CsvImportMetadata.Delimiter.allCases, id: \.self) { delimiter in
                        Text(verbatim: TextImportModel.title(delimiter)).tag(delimiter)
                    }
                }
                .disabled(model.metadata.forcesDelimiter)
                Toggle("Fields contain HTML", isOn: Binding(get: { model.metadata.isHTML }, set: { model.setHTML($0) }))
                    .disabled(model.metadata.forcesIsHTML)
            }
            Section("Notes") {
                notetypeRow
                deckRow
            }
            fieldsSection
            Section {
                Picker("Tags", selection: Binding(get: { model.metadata.tagsColumn }, set: { model.chooseTagsColumn($0) })) {
                    Text("None").tag(0)
                    columnOptions
                }
                Picker("Notes already there", selection: Binding(get: { model.metadata.duplicates }, set: { model.chooseDuplicates($0) })) {
                    Text("Update them").tag(CsvImportMetadata.Duplicates.update)
                    Text("Leave them as they are").tag(CsvImportMetadata.Duplicates.preserve)
                    Text("Add them again").tag(CsvImportMetadata.Duplicates.duplicate)
                }
            } footer: {
                Text("A note is already there when one of the same note type has the same first field.")
            }
        }
        .disabled(model.phase == .importing)
        .overlay {
            if model.phase == .importing {
                ProgressView("Importing…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var fileSection: some View {
        Section {
            LabeledContent("File", value: model.file.fileName)
            ForEach(Array(model.metadata.preview.prefix(3).enumerated()), id: \.offset) { _, row in
                Text(verbatim: TextImportModel.previewLine(row))
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
            }
        } footer: {
            Text("One note per line. The first lines of the file are shown above.")
        }
    }

    @ViewBuilder
    private var notetypeRow: some View {
        if case .column(let column)? = model.metadata.notetype {
            LabeledContent("Note type", value: "Named in column \(column)")
        } else {
            Picker("Note type", selection: notetypeBinding) {
                ForEach(model.notetypes) { notetype in
                    Text(verbatim: notetype.name).tag(NotetypeID?.some(notetype.id))
                }
            }
        }
    }

    private var deckRow: some View {
        Picker("Deck", selection: Binding(get: { model.chosenDeckId }, set: { model.chooseDeck($0) })) {
            if let fileDeck = model.fileDeck {
                Text(verbatim: Self.title(fileDeck)).tag(DeckID?.none)
            }
            ForEach(model.decks) { deck in
                Text(verbatim: deck.name).tag(DeckID?.some(deck.id))
            }
        }
    }

    @ViewBuilder
    private var fieldsSection: some View {
        if case .global? = model.metadata.notetype, !model.fieldNames.isEmpty {
            Section {
                ForEach(Array(model.fieldNames.enumerated()), id: \.offset) { index, name in
                    Picker(selection: Binding(get: { model.column(forField: index) }, set: { model.chooseColumn($0, forField: index) })) {
                        Text("Nothing").tag(0)
                        columnOptions
                    } label: {
                        Text(verbatim: name)
                    }
                }
            } header: {
                Text("Fields")
            } footer: {
                Text("The column that fills each field of the note.")
            }
        }
    }

    private var columnOptions: some View {
        ForEach(model.columns) { column in
            Text(verbatim: column.title).tag(column.number)
        }
    }

    private var delimiterBinding: Binding<CsvImportMetadata.Delimiter> {
        Binding(
            get: { model.metadata.delimiter },
            set: { delimiter in Task { await model.chooseDelimiter(delimiter) } }
        )
    }

    private var notetypeBinding: Binding<NotetypeID?> {
        Binding(
            get: { model.chosenNotetypeId },
            set: { id in
                guard let id else { return }
                Task { await model.chooseNotetype(id) }
            }
        )
    }

    private static func title(_ deck: CsvImportMetadata.DeckSource) -> String {
        switch deck {
        case .new(let name): "\(name) (new deck)"
        case .column(let column): "Named in column \(column)"
        case .existing: "From the file"
        }
    }

    // MARK: Finished

    private func finished(_ summary: CsvImportSummary) -> some View {
        List {
            Section {
                VStack(spacing: AmgiSpacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(palette.positive)
                        .accessibilityHidden(true)
                    Text("Imported")
                        .amgiFont(.sectionHeading)
                        .foregroundStyle(palette.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AmgiSpacing.sm)
            }
            Section {
                ForEach(TextImportModel.summaryLines(summary), id: \.self) { line in
                    Text(verbatim: line)
                }
            } footer: {
                Text("The new notes' cards are new cards, in the deck you chose.")
            }
        }
    }
}
