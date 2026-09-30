//
//  MnemonicClient.swift
//  MnemonicCore
//

public import AnkiKit
public import Dependencies
import AnkiClients

/// Engine-facing half of the mnemonic workflow. Thin on purpose: every
/// decision lives in `MnemonicNoteEditor`, which is pure and tested; this
/// only fetches, hands the note over, and saves what comes back.
///
/// Every write starts from a fresh `fetch` by note ID, never from a copy a
/// screen is holding. That is what makes an edit made elsewhere between
/// capture and approval survive — the stale-snapshot overwrite can't happen
/// because no snapshot is ever written back.
public struct MnemonicClient: Sendable {
    /// Saves an idea onto the note. One note write, no network.
    public var capture: @Sendable (_ noteId: NoteID, _ idea: String) async throws -> Void
    /// Every idea still waiting for a picture, across the collection.
    public var pending: @Sendable () async throws -> [PendingMnemonic]
    public var updateIdea: @Sendable (_ item: PendingMnemonic, _ idea: String) async throws -> Void
    /// Writes the picture to media, then swaps the idea for it. Idempotent.
    public var approve: @Sendable (_ item: PendingMnemonic, _ prompt: String, _ image: MnemonicImage) async throws -> Void
    public var discard: @Sendable (_ item: PendingMnemonic) async throws -> Void
    /// Writes a picture to media and adds it straight to the note's extra
    /// field, with no pending idea involved.
    public var attach: @Sendable (_ noteId: NoteID, _ prompt: String, _ image: MnemonicImage) async throws -> Void

    public init(
        capture: @escaping @Sendable (_ noteId: NoteID, _ idea: String) async throws -> Void,
        pending: @escaping @Sendable () async throws -> [PendingMnemonic],
        updateIdea: @escaping @Sendable (_ item: PendingMnemonic, _ idea: String) async throws -> Void,
        approve: @escaping @Sendable (_ item: PendingMnemonic, _ prompt: String, _ image: MnemonicImage) async throws -> Void,
        discard: @escaping @Sendable (_ item: PendingMnemonic) async throws -> Void,
        attach: @escaping @Sendable (_ noteId: NoteID, _ prompt: String, _ image: MnemonicImage) async throws -> Void
    ) {
        self.capture = capture
        self.pending = pending
        self.updateIdea = updateIdea
        self.approve = approve
        self.discard = discard
        self.attach = attach
    }
}

extension MnemonicClient: DependencyKey {
    public static let liveValue: MnemonicClient = {
        @Dependency(\.noteClient) var notes
        @Dependency(\.notetypesClient) var notetypes
        @Dependency(\.mediaClient) var media

        return MnemonicClient(
            capture: { noteId, idea in
                guard let note = try await notes.fetch(noteId) else { throw MnemonicError.noteNotFound }
                let fieldNames = try await notetypes.get(note.mid).fields.map(\.name)
                let updated = MnemonicNoteEditor.capturing(
                    idea: idea,
                    markerId: MnemonicMarker.newID(),
                    in: note,
                    fieldNames: fieldNames
                )
                try await notes.save(updated)
            },
            pending: {
                let waiting = try await notes.searchAll("tag:\(MnemonicNoteEditor.pendingTag)", nil)
                var fieldNamesByNotetype: [NotetypeID: [String]] = [:]
                var items: [PendingMnemonic] = []
                for note in waiting {
                    let fieldNames: [String]
                    if let cached = fieldNamesByNotetype[note.mid] {
                        fieldNames = cached
                    } else {
                        fieldNames = (try? await notetypes.get(note.mid).fields.map(\.name)) ?? []
                        fieldNamesByNotetype[note.mid] = fieldNames
                    }
                    items += MnemonicNoteEditor.pendingItems(in: note, fieldNames: fieldNames)
                }
                return items
            },
            updateIdea: { item, idea in
                guard let note = try await notes.fetch(item.noteId) else { throw MnemonicError.noteNotFound }
                switch MnemonicNoteEditor.updatingIdea(markerId: item.markerId, to: idea, in: note) {
                case .updated(let updated):
                    try await notes.save(updated)
                case .alreadyApplied:
                    return
                case .markerMissing:
                    throw MnemonicError.ideaMissing
                }
            },
            approve: { item, prompt, image in
                guard let note = try await notes.fetch(item.noteId) else { throw MnemonicError.noteNotFound }
                let filename = MnemonicNoteEditor.mediaFilename(
                    noteId: item.noteId,
                    markerId: item.markerId,
                    fileExtension: image.fileExtension
                )
                switch MnemonicNoteEditor.approving(
                    markerId: item.markerId,
                    prompt: prompt,
                    mediaFilename: filename,
                    in: note
                ) {
                case .updated(let updated):
                    // Media first: a note must never point at a file that
                    // isn't there. If the note write then fails, the file is
                    // an orphan that Check Media cleans up — harmless.
                    try await media.save(image.data, filename)
                    try await notes.save(updated)
                case .alreadyApplied:
                    return
                case .markerMissing:
                    throw MnemonicError.ideaMissing
                }
            },
            discard: { item in
                guard let note = try await notes.fetch(item.noteId) else { throw MnemonicError.noteNotFound }
                switch MnemonicNoteEditor.discarding(markerId: item.markerId, in: note) {
                case .updated(let updated):
                    try await notes.save(updated)
                case .alreadyApplied, .markerMissing:
                    return
                }
            },
            attach: { noteId, prompt, image in
                guard let note = try await notes.fetch(noteId) else { throw MnemonicError.noteNotFound }
                let fieldNames = try await notetypes.get(note.mid).fields.map(\.name)
                let markerId = MnemonicMarker.newID()
                let filename = MnemonicNoteEditor.mediaFilename(
                    noteId: noteId,
                    markerId: markerId,
                    fileExtension: image.fileExtension
                )
                let updated = MnemonicNoteEditor.attaching(
                    prompt: prompt,
                    markerId: markerId,
                    mediaFilename: filename,
                    to: note,
                    fieldNames: fieldNames
                )
                // Media first, as in approve: a note must never point at a
                // file that isn't there.
                try await media.save(image.data, filename)
                try await notes.save(updated)
            }
        )
    }()

    public static let testValue = MnemonicClient(
        capture: { _, _ in throw MnemonicError.unimplemented("MnemonicClient.capture") },
        pending: { throw MnemonicError.unimplemented("MnemonicClient.pending") },
        updateIdea: { _, _ in throw MnemonicError.unimplemented("MnemonicClient.updateIdea") },
        approve: { _, _, _ in throw MnemonicError.unimplemented("MnemonicClient.approve") },
        discard: { _ in throw MnemonicError.unimplemented("MnemonicClient.discard") },
        attach: { _, _, _ in throw MnemonicError.unimplemented("MnemonicClient.attach") }
    )
}

extension DependencyValues {
    public var mnemonicClient: MnemonicClient {
        get { self[MnemonicClient.self] }
        set { self[MnemonicClient.self] = newValue }
    }
}
