//
//  GraveyardCardView.swift
//  GraveyardFeature
//

import SwiftUI
import AnkiClients
import AnkiKit
import AppCore
import AppShared
import BrowseFeature
import Dependencies
import MnemonicCore
import Observation

/// The card as the assistant sees it, built from a note and its note type.
enum CardSnapshots {
    static func make(note: NoteRecord, notetype: Notetype, deckName: String) -> CardSnapshot {
        let names = notetype.fields.map(\.name)
        let values = CardFieldEdits.splitFields(note.flds)
        return CardSnapshot(
            notetypeName: notetype.name,
            deckName: deckName,
            fields: values.enumerated().map { index, value in
                CardSnapshot.Field(name: index < names.count ? names[index] : "Field \(index + 1)", value: value)
            }
        )
    }
}

@Observable
@MainActor
final class GraveyardCardModel {
    let item: GraveyardItem
    private(set) var note: NoteRecord?
    private(set) var snapshot: CardSnapshot?
    /// How many cards the note has, for the delete confirmation.
    private(set) var cardCount = 1
    private(set) var isWorking = false
    var errorMessage: String?

    @ObservationIgnored @Dependency(\.noteClient) private var noteClient
    @ObservationIgnored @Dependency(\.notetypesClient) private var notetypesClient
    @ObservationIgnored @Dependency(\.cardClient) private var cardClient
    @ObservationIgnored @Dependency(\.collectionStore) private var collectionStore

    init(item: GraveyardItem) {
        self.item = item
    }

    func load() async {
        do {
            guard let note = try await noteClient.fetch(item.noteId) else { throw CardReviewError.noteGone }
            let notetype = try await notetypesClient.get(note.mid)
            self.note = note
            snapshot = CardSnapshots.make(note: note, notetype: notetype, deckName: item.deckName)
            cardCount = max((try? await cardClient.fetchByNote(item.noteId).count) ?? 1, 1)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A starting description for a picture: the front, then the back.
    var suggestedPictureIdea: String {
        let fields = snapshot?.fields ?? []
        return fields.prefix(2)
            .map { MnemonicText.summary($0.value, limit: 200) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// Starts the fixed card over as a new card, then clears its flag, so it
    /// leaves the Graveyard and is learned again from scratch. It goes back
    /// to its old place among the new cards, where Anki knows it, so it's
    /// soon among the New button's cards; its review and lapse counts are
    /// cleared too, or the problem-card rule would flag it again the first
    /// time it's missed. Reset first: if that fails, the card keeps its
    /// flag and stays here to try again.
    func markFixed() async -> Bool {
        let cardId = item.cardId
        let cardClient = self.cardClient
        return await run {
            try await cardClient.startOver(cardId, true, true)
            try await cardClient.flag(cardId, 0)
        }
    }

    func deleteNote() async -> Bool {
        let noteId = item.noteId
        let noteClient = self.noteClient
        return await run { try await noteClient.delete(noteId) }
    }

    private func run(_ work: () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            // The card rejoins (or leaves) the pool the Library's Reviews
            // count is taken from.
            collectionStore.invalidateAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// One flagged card: what it says, and the ways to deal with it.
struct GraveyardCardView: View {
    let item: GraveyardItem
    /// Called after the card was fixed or deleted, so the list reloads.
    let onChange: () -> Void

    @State private var model: GraveyardCardModel
    @State private var showChat = false
    @State private var showPicture = false
    @State private var editNote: NoteRecord?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(item: GraveyardItem, onChange: @escaping () -> Void) {
        self.item = item
        self.onChange = onChange
        _model = State(initialValue: GraveyardCardModel(item: item))
    }

    var body: some View {
        List {
            fieldsSection

            Section {
                Button {
                    showChat = true
                } label: {
                    Label("Ask AI", systemImage: "bubble.left.and.text.bubble.right")
                }
                Button {
                    showPicture = true
                } label: {
                    Label("Add a Picture to Extra", systemImage: "photo.badge.plus")
                }
                Button {
                    editNote = model.note
                } label: {
                    Label("Edit by Hand", systemImage: "pencil")
                }
                .disabled(model.note == nil)
            } header: {
                Text("Fix it")
            }

            Section {
                Button {
                    Task {
                        if await model.markFixed() {
                            onChange()
                            dismiss()
                        }
                    }
                } label: {
                    Label("Mark as Fixed", systemImage: "checkmark.circle")
                }
            } footer: {
                Text("Starts the card over as a new card and removes the flag, so you learn the fixed version from scratch. It goes back to its original place in your new cards.")
            }

            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Note", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Flagged Card")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isWorking)
        .task { await model.load() }
        .sheet(isPresented: $showChat, onDismiss: { Task { await model.load() } }) {
            CardReviewChatView(noteId: item.noteId, deckName: item.deckName)
        }
        .sheet(isPresented: $showPicture, onDismiss: { Task { await model.load() } }) {
            GraveyardPictureSheet(noteId: item.noteId, suggestedIdea: model.suggestedPictureIdea)
        }
        .sheet(item: $editNote, onDismiss: { Task { await model.load() } }) { note in
            NavigationStack {
                NoteEditorView(note: note) {}
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.deleteNote() {
                        onChange()
                        dismiss()
                    }
                }
            }
        } message: {
            Text(deleteMessage)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private var headerTitle: String {
        let flag = "\(CardFlag.name(item.flag)) flag"
        return item.deckName.isEmpty ? flag : "\(flag) · \(item.deckName)"
    }

    private var deleteMessage: String {
        model.cardCount > 1
            ? "This deletes the note and all \(model.cardCount) of its cards."
            : "This deletes the note and its card."
    }

    @ViewBuilder
    private var fieldsSection: some View {
        Section {
            if let snapshot = model.snapshot {
                ForEach(Array(snapshot.fields.enumerated()), id: \.offset) { _, field in
                    FieldRow(field: field)
                }
            } else {
                ProgressView()
            }
        } header: {
            Label(headerTitle, systemImage: "flag.fill")
                .foregroundStyle(CardFlag.color(item.flag))
        }
    }
}

private struct FieldRow: View {
    let field: CardSnapshot.Field

    private var pictureCount: Int {
        field.value.components(separatedBy: "<img").count - 1
    }

    private var pictureLabel: String {
        pictureCount == 1 ? "1 picture" : "\(pictureCount) pictures"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            let text = MnemonicText.summary(field.value, limit: 4000)
            Text(text.isEmpty ? "—" : text)
                .textSelection(.enabled)
            if pictureCount > 0 {
                Label(pictureLabel, systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
