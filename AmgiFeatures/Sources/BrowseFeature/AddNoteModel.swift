//
//  AddNoteModel.swift
//  BrowseFeature
//
//  Created by Vladimir Gusev on 22.06.2026.
//

import OSLog
import AppCore
import AppShared
import AnkiBackend
import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import SwiftUI

/// Data state + load/save logic for the Add Note form. Mirrors the other
/// screen models: the View owns navigation, the toolbar, and dismissal,
/// while the model owns deck/notetype loading, field assembly, and the note
/// write so the form stays testable and the View stays thin.
@Observable
@MainActor
final class AddNoteModel {
    var decks: [DeckInfo] = []
    var notetypeNames: [(id: NotetypeID, name: String)] = []
    var selectedDeckId: DeckID = DeckID(1)
    var selectedNotetypeId: NotetypeID = NotetypeID(0)
    var fieldNames: [String] = []
    var fieldValues: [String] = []
    /// The fields the chosen note type's cloze deletions go in; empty
    /// unless it's a cloze type.
    var clozeFieldNames: [String] = []
    /// The chosen note type's pinned fields, by name: they keep what's in
    /// them for the next note. See `togglePin`.
    var pinnedFieldNames: Set<String> = []
    /// Notes added since the screen opened; it stays open for the next.
    private(set) var addedCount = 0
    var tags: String = ""
    var isSaving = false
    var errorMessage: String?

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.notetypesService) private var notetypesService
    @ObservationIgnored @Dependency(\.notesService) private var notesService
    @ObservationIgnored @Dependency(\.collectionStore) private var store

    @ObservationIgnored private let preselectedDeckId: DeckID?
    @ObservationIgnored private let initialDraft: AddNoteDraft?

    @ObservationIgnored private var baselineFieldValues: [String] = []
    @ObservationIgnored private var baselineTags: String = ""

    var hasUnsavedChanges: Bool {
        fieldValues != baselineFieldValues || tags != baselineTags
    }

    init(preselectedDeckId: DeckID? = nil, initialDraft: AddNoteDraft? = nil) {
        self.preselectedDeckId = preselectedDeckId
        self.initialDraft = initialDraft
    }

    /// Positional projection into `fieldValues`, read through `@Bindable` as
    /// `$model[fieldAt: index]`. A subscript rather than a
    /// `Binding(get:set:)`-returning method so the field editors get a stable
    /// binding instead of a freshly-allocated closure pair on every body pass.
    subscript(fieldAt index: Int) -> String {
        get { index < fieldValues.count ? fieldValues[index] : "" }
        set { if index < fieldValues.count { fieldValues[index] = newValue } }
    }

    /// Whether the field at `index` takes cloze deletions, and so the
    /// editor's cloze buttons.
    func isClozeField(_ index: Int) -> Bool {
        index < fieldNames.count && clozeFieldNames.contains(fieldNames[index])
    }

    // MARK: - Pinned fields

    func isPinned(_ index: Int) -> Bool {
        index < fieldNames.count && pinnedFieldNames.contains(fieldNames[index])
    }

    /// Pins the field at `index`, or unpins it. Remembered for the note
    /// type, on this phone.
    func togglePin(_ index: Int) {
        guard index < fieldNames.count else { return }
        let name = fieldNames[index]
        if pinnedFieldNames.contains(name) {
            pinnedFieldNames.remove(name)
        } else {
            pinnedFieldNames.insert(name)
        }
        UserDefaults.standard.set(pinnedFieldNames.sorted(), forKey: Self.pinnedFieldsKey(for: selectedNotetypeId))
    }

    /// The first field that starts empty for the next note.
    var firstUnpinnedFieldIndex: Int? {
        fieldNames.indices.first { !isPinned($0) }
    }

    /// Something to add: a field that isn't pinned has something in it (or
    /// any field, when they're all pinned).
    var hasNewContent: Bool {
        let unpinned = fieldValues.indices.filter { !isPinned($0) }
        let considered = unpinned.isEmpty ? Array(fieldValues.indices) : unpinned
        return considered.contains { !fieldValues[$0].isEmpty }
    }

    /// Ready for the next note once one is added: pinned fields keep what's
    /// in them, the rest start empty; the deck, note type and tags stay, as
    /// in Anki's Add window.
    func startNextNote() {
        fieldValues = fieldValues.indices.map { isPinned($0) ? fieldValues[$0] : "" }
        baselineFieldValues = fieldValues
        baselineTags = tags
        errorMessage = nil
        addedCount += 1
    }

    private static func pinnedFieldsKey(for notetype: NotetypeID) -> String {
        "add_note_pinned_fields_\(notetype.rawValue)"
    }

    func loadData() async {
        decks = (try? await deckClient.fetchAll()) ?? []
        if let preselectedDeckId, decks.contains(where: { $0.id == preselectedDeckId }) {
            selectedDeckId = preselectedDeckId
        } else if let first = decks.first {
            selectedDeckId = first.id
        }

        do {
            let service = notetypesService
            notetypeNames = try await backendOffload { try service.getNotetypeNames() }
            // Honour an incoming draft's preferred notetype when it matches
            // one the user actually has; otherwise Cloze, then the first.
            var chosen = initialDraft?.notetypeID
                .flatMap { id in notetypeNames.first(where: { $0.id.rawValue == id }) }
            if chosen == nil {
                chosen = await clozeNotetype() ?? notetypeNames.first
            }
            if let chosen {
                selectedNotetypeId = chosen.id
                await loadFields()
            }
        } catch {
            Log.browse.error("Error loading notetypes: \(error)")
        }

        if let initialDraft, !initialDraft.tags.isEmpty {
            tags = initialDraft.tags.joined(separator: " ")
        }
        baselineTags = tags
    }

    /// The note type a new note starts as: Anki's own Cloze when it's
    /// there, otherwise the first cloze type (never Image Occlusion).
    private func clozeNotetype() async -> (id: NotetypeID, name: String)? {
        let service = notetypesService
        var clozeTypes: [(id: NotetypeID, name: String)] = []
        for entry in notetypeNames {
            let id = entry.id
            if let info = try? await backendOffload({ try service.getNotetype(id) }), info.isCloze {
                clozeTypes.append(entry)
            }
        }
        return clozeTypes.first { $0.name == "Cloze" } ?? clozeTypes.first
    }

    func loadFields() async {
        guard selectedNotetypeId.rawValue != 0 else { return }
        do {
            let service = notetypesService
            let id = selectedNotetypeId
            let notetype = try await backendOffload { try service.getNotetype(id) }
            fieldNames = notetype.fieldNames
            clozeFieldNames = notetype.clozeFieldNames
            // Pinned here before, or else as in Anki's Add window.
            let pinned = UserDefaults.standard.stringArray(forKey: Self.pinnedFieldsKey(for: id))
            pinnedFieldNames = Set(pinned ?? notetype.stickyFieldNames)
            // Pre-fill from the incoming draft by mapping
            // `fieldValues[name] → fieldValues[positionalIndex]` against the
            // notetype's actual field-name list. Names not present on this
            // notetype are silently dropped.
            fieldValues = fieldNames.map { name in
                initialDraft?.fieldValues[name] ?? ""
            }
            baselineFieldValues = fieldValues
        } catch {
            Log.browse.error("Error loading fields: \(error)")
        }
    }

    /// Persist the note. Returns whether the write succeeded; on failure
    /// `errorMessage` carries the reason. Navigation/dismissal stays with
    /// the View.
    func save() async -> Bool {
        // A cloze note makes a card for each number in its deletions: with
        // none, there'd be nothing to study.
        if !clozeFieldNames.isEmpty,
           !fieldValues.indices.contains(where: { isClozeField($0) && !ClozeEditing.numbers(in: fieldValues[$0]).isEmpty }) {
            errorMessage = "Hide something first: select words in \(clozeFieldNames[0]) and tap Cloze above the keyboard."
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let notes = notesService
            let notetypeID = selectedNotetypeId
            let deckID = selectedDeckId
            let fields = fieldValues
            let tagList = tags.split(separator: " ").map(String.init)
            try await backendOffload {
                var template = try notes.newNote(notetypeID)
                template.fields = fields
                template.tags = tagList
                try notes.addNote(template, deckID)
            }
            // addNote doesn't surface OpChanges yet — invalidate the shared
            // tree cache conservatively so every host (DeckDetail, reader
            // lookup, Browse) sees fresh counts.
            store.apply(CollectionChanges(card: true, note: true, studyQueues: true))
            return true
        } catch {
            errorMessage = "Failed to add note: \(error.localizedDescription)"
            return false
        }
    }
}
