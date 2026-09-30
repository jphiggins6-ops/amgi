//
//  MnemonicNoteEditor.swift
//  MnemonicCore
//

public import AnkiKit
import Foundation

/// One idea waiting in a note for its picture.
public struct PendingMnemonic: Identifiable, Hashable, Sendable {
    public let noteId: NoteID
    /// The marker's ID — unique within its note.
    public let markerId: String
    public var idea: String
    /// The field the picture will go into, e.g. "Extra".
    public let fieldName: String
    /// The card's first field as plain text, for context in the review list.
    public let cardSummary: String

    public var id: String { "\(noteId.rawValue):\(markerId)" }

    public init(noteId: NoteID, markerId: String, idea: String, fieldName: String, cardSummary: String) {
        self.noteId = noteId
        self.markerId = markerId
        self.idea = idea
        self.fieldName = fieldName
        self.cardSummary = cardSummary
    }
}

/// Pure note rewrites for the mnemonic workflow: no engine, no I/O.
///
/// Every function takes the note it should change and returns the changed
/// copy. The caller is responsible for passing the note *as it is now* —
/// `MnemonicClient` refetches by ID before every write — so an edit made
/// elsewhere between capture and approval is kept rather than overwritten
/// with a stale snapshot.
public enum MnemonicNoteEditor {
    public static let pendingTag = "mnemonic::pending"
    public static let doneTag = "mnemonic::done"

    public enum Outcome: Equatable {
        case updated(NoteRecord)
        /// The picture is already in the note — a retry after a write that
        /// did land. Nothing to do.
        case alreadyApplied
        /// The pending idea is gone: discarded, or edited out on another device.
        case markerMissing
    }

    /// Where a picture goes when a notetype doesn't say. AnKing-style notes
    /// have "Extra", Anki's Cloze has "Back Extra", Basic has "Back";
    /// anything else gets its last field, which is where extras usually live.
    public static func targetFieldIndex(fieldNames: [String]) -> Int {
        for preferred in ["extra", "back extra", "back"] {
            if let index = fieldNames.firstIndex(where: { $0.lowercased() == preferred }) {
                return index
            }
        }
        return max(fieldNames.count - 1, 0)
    }

    public static func mediaFilename(noteId: NoteID, markerId: String, fileExtension: String) -> String {
        "amgi-mnemonic-\(noteId.rawValue)-\(markerId).\(fileExtension)"
    }

    // MARK: - Capture

    public static func capturing(
        idea: String,
        markerId: String,
        in note: NoteRecord,
        fieldNames: [String]
    ) -> NoteRecord {
        var fields = splitFields(note.flds)
        while fields.count < max(fieldNames.count, 1) { fields.append("") }
        let target = min(targetFieldIndex(fieldNames: fieldNames), fields.count - 1)
        fields[target] += MnemonicMarker.pending(id: markerId, idea: idea)

        var updated = withFields(fields, in: note)
        updated.tags = adding(pendingTag, to: updated.tags)
        return updated
    }

    /// Adds a finished picture straight to the note, with no idea waiting
    /// first — for pictures made on the spot rather than from the ✨ inbox.
    /// Goes where an approved idea's picture would go, in the same block, so
    /// the two look and behave alike.
    public static func attaching(
        prompt: String,
        markerId: String,
        mediaFilename: String,
        to note: NoteRecord,
        fieldNames: [String]
    ) -> NoteRecord {
        var fields = splitFields(note.flds)
        while fields.count < max(fieldNames.count, 1) { fields.append("") }
        let target = min(targetFieldIndex(fieldNames: fieldNames), fields.count - 1)
        fields[target] += MnemonicMarker.doneBlock(id: markerId, prompt: prompt, mediaFilename: mediaFilename)

        var updated = withFields(fields, in: note)
        updated.tags = adding(doneTag, to: updated.tags)
        return updated
    }

    public static func pendingItems(in note: NoteRecord, fieldNames: [String]) -> [PendingMnemonic] {
        let fields = splitFields(note.flds)
        let summary = MnemonicText.summary(fields.first ?? "")
        var items: [PendingMnemonic] = []
        for (index, field) in fields.enumerated() {
            let fieldName = index < fieldNames.count ? fieldNames[index] : "Field \(index + 1)"
            for found in MnemonicMarker.pendingMarkers(in: field) {
                items.append(PendingMnemonic(
                    noteId: note.id,
                    markerId: found.id,
                    idea: found.idea,
                    fieldName: fieldName,
                    cardSummary: summary
                ))
            }
        }
        return items
    }

    // MARK: - Resolve

    /// Swaps the pending marker for the picture. Idempotent: if the picture
    /// for this marker is already present, reports `.alreadyApplied`.
    public static func approving(
        markerId: String,
        prompt: String,
        mediaFilename: String,
        in note: NoteRecord
    ) -> Outcome {
        var fields = splitFields(note.flds)
        if fields.contains(where: { MnemonicMarker.containsDone(id: markerId, in: $0) }) {
            return .alreadyApplied
        }
        guard let (index, found) = locatePending(markerId, in: fields) else { return .markerMissing }

        fields[index].replaceSubrange(
            found.range,
            with: MnemonicMarker.doneBlock(id: markerId, prompt: prompt, mediaFilename: mediaFilename)
        )
        var updated = withFields(fields, in: note)
        updated.tags = syncPendingTag(adding(doneTag, to: updated.tags), fields: fields)
        return .updated(updated)
    }

    public static func discarding(markerId: String, in note: NoteRecord) -> Outcome {
        var fields = splitFields(note.flds)
        guard let (index, found) = locatePending(markerId, in: fields) else { return .markerMissing }

        fields[index].removeSubrange(found.range)
        var updated = withFields(fields, in: note)
        updated.tags = syncPendingTag(updated.tags, fields: fields)
        return .updated(updated)
    }

    /// Saves an edited description back into the note, so it survives
    /// leaving the review screen without approving.
    public static func updatingIdea(markerId: String, to idea: String, in note: NoteRecord) -> Outcome {
        var fields = splitFields(note.flds)
        guard let (index, found) = locatePending(markerId, in: fields) else { return .markerMissing }

        fields[index].replaceSubrange(found.range, with: MnemonicMarker.pending(id: markerId, idea: idea))
        return .updated(withFields(fields, in: note))
    }

    // MARK: - Fields and tags

    static func splitFields(_ flds: String) -> [String] {
        flds.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
    }

    static func withFields(_ fields: [String], in note: NoteRecord) -> NoteRecord {
        var updated = note
        updated.flds = fields.joined(separator: "\u{1f}")
        updated.sfld = fields.first ?? ""
        return updated
    }

    static func tagList(_ tags: String) -> [String] {
        tags.split(separator: " ").map(String.init)
    }

    /// Anki tags are case-insensitive, so membership is too.
    static func adding(_ tag: String, to tags: String) -> String {
        var list = tagList(tags)
        if !list.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            list.append(tag)
        }
        return list.joined(separator: " ")
    }

    static func removing(_ tag: String, from tags: String) -> String {
        tagList(tags)
            .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            .joined(separator: " ")
    }

    /// The pending tag is an index into the notes, so it has to mean "this
    /// note still has an idea waiting" — no more, no less.
    private static func syncPendingTag(_ tags: String, fields: [String]) -> String {
        let stillPending = fields.contains { !MnemonicMarker.pendingMarkers(in: $0).isEmpty }
        return stillPending ? adding(pendingTag, to: tags) : removing(pendingTag, from: tags)
    }

    private static func locatePending(
        _ markerId: String,
        in fields: [String]
    ) -> (Int, MnemonicMarker.Found)? {
        for (index, field) in fields.enumerated() {
            if let found = MnemonicMarker.pendingMarkers(in: field).first(where: { $0.id == markerId }) {
                return (index, found)
            }
        }
        return nil
    }
}
