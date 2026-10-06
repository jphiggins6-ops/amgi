//
//  NoteEditorModel.swift
//  BrowseFeature
//
//  Created by Vladimir Gusev on 22.06.2026.
//

import OSLog
import AppCore
import AnkiBackend
import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import Foundation
import SwiftUI

/// Field/tag state + load/save logic for editing an existing note. The View
/// owns the toolbar and the "Saved" toast; the model owns notetype lookup,
/// field unpacking, and the note write so the form stays testable.
@Observable
@MainActor
final class NoteEditorModel {
    var fieldNames: [String] = []
    var fieldValues: [String] = []
    /// The fields the note type's cloze deletions go in; empty unless it's
    /// a cloze type.
    var clozeFieldNames: [String] = []
    var tags: String = ""
    var isSaving = false
    /// Bumped by each paste. The field editors are rebuilt from it, so they
    /// show what was added, and a field that gained a picture switches to
    /// HTML editing.
    private(set) var pasteCount = 0
    var pasteError: String?

    @ObservationIgnored @Dependency(\.noteClient) private var noteClient
    @ObservationIgnored @Dependency(\.notetypesService) private var notetypesService
    @ObservationIgnored @Dependency(\.mediaClient) private var mediaClient
    @ObservationIgnored private let note: NoteRecord

    init(note: NoteRecord) {
        self.note = note
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

    func loadNote() async {
        do {
            let service = notetypesService
            let mid = note.mid
            let notetype = try await backendOffload { try service.getNotetype(mid) }
            fieldNames = notetype.fieldNames
            clozeFieldNames = notetype.clozeFieldNames
        } catch {
            Log.browse.error("Error loading notetype: \(error)")
        }

        fieldValues = note.flds
            .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map(String.init)
        while fieldValues.count < fieldNames.count { fieldValues.append("") }
        tags = note.tags.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Paste

    /// The field Paste adds to; see `NotePaste.targetFieldIndex`.
    var pasteTargetIndex: Int? {
        NotePaste.targetFieldIndex(fieldNames: fieldNames, fieldCount: fieldValues.count)
    }

    var pasteTargetName: String? {
        guard let index = pasteTargetIndex, index < fieldNames.count else { return nil }
        return fieldNames[index]
    }

    /// Adds what was copied, pictures and text in clipboard order, to the
    /// end of the field extras go in. A picture is stored as media straight
    /// away; the note itself waits for Save, like any other edit.
    func paste(_ items: [PastedItem]) async {
        var parts: [String] = []
        var failedPictures = 0
        for item in items {
            switch item {
            case .text(let text):
                let html = NotePaste.html(forText: text)
                if !html.isEmpty { parts.append(html) }
            case .image(let data):
                if let tag = await storePicture(data) {
                    parts.append(tag)
                } else {
                    failedPictures += 1
                }
            }
        }
        if failedPictures > 0 {
            pasteError = failedPictures == 1
                ? "The picture couldn't be added."
                : "\(failedPictures) pictures couldn't be added."
        }
        guard !parts.isEmpty, let target = pasteTargetIndex else { return }
        fieldValues[target] = NotePaste.appending(parts.joined(separator: "<br>"), to: fieldValues[target])
        pasteCount += 1
    }

    /// Saves a pasted picture to the media folder; returns the tag that
    /// shows it on the card.
    private func storePicture(_ data: Data) async -> String? {
        await NotePaste.storePicture(data, in: mediaClient)
    }

    // MARK: - Save

    /// Persist the edited fields/tags. Returns whether the write succeeded.
    func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }

        let newFlds = fieldValues.joined(separator: "\u{1f}")
        let newSfld = fieldValues.first ?? ""
        let newCsum = Int64(newSfld.hashValue & 0xFFFFFFFF)

        var updatedNote = note
        updatedNote.flds = newFlds
        updatedNote.sfld = newSfld
        updatedNote.csum = newCsum
        updatedNote.tags = " \(tags) "

        do {
            try await noteClient.save(updatedNote)
            return true
        } catch {
            return false
        }
    }
}
