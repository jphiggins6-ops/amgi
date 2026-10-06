//
//  AddNoteView.swift
//  BrowseFeature
//
//  Created by Vladimir Gusev on 30.03.2026.
//

package import SwiftUI
package import AnkiKit
import Theme

/// Add Note container: owns the modal chrome (navigation, toolbar, dismissal)
/// and drives an `AddNoteModel` for deck/notetype loading and the note write.
/// The form itself is `AddNoteContent`, bound to the model.
package struct AddNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: AddNoteModel
    @State private var showDiscardConfirm = false
    let onSave: () -> Void

    package init(
        preselectedDeckId: DeckID? = nil,
        initialDraft: AddNoteDraft? = nil,
        onSave: @escaping () -> Void
    ) {
        let resolved = preselectedDeckId ?? initialDraft?.deckID.map { DeckID($0) }
        _model = State(initialValue: AddNoteModel(preselectedDeckId: resolved, initialDraft: initialDraft))
        self.onSave = onSave
    }

    package var body: some View {
        NavigationStack {
            AddNoteContent(model: model)
                .navigationTitle("Add Note")
                .navigationBarTitleDisplayMode(.inline)
                .interactiveDismissDisabled(model.hasUnsavedChanges)
                .confirmationDialog(
                    "Discard this note?",
                    isPresented: $showDiscardConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Discard", role: .destructive) { dismiss() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The note hasn't been added yet. Discarding loses what you typed.")
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            if model.hasUnsavedChanges {
                                showDiscardConfirm = true
                            } else {
                                dismiss()
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            Task {
                                if await model.save() {
                                    onSave()
                                    dismiss()
                                }
                            }
                        }
                        .disabled(model.isSaving || model.fieldValues.allSatisfy(\.isEmpty))
                    }
                }
                .task { await model.loadData() }
        }
    }
}

// MARK: - AddNoteContent

/// The Add Note form: deck + note-type pickers, the note-type's fields, and a
/// tags field. Bound to an `AddNoteModel`; owns no I/O of its own, so it
/// renders in a `#Preview` from a seeded model.
struct AddNoteContent: View {
    @Environment(\.palette) private var palette
    @Bindable var model: AddNoteModel

    var body: some View {
        Form {
            Section("Deck") {
                Picker("Deck", selection: $model.selectedDeckId) {
                    ForEach(model.decks) { deck in
                        Text(deck.name).tag(deck.id)
                    }
                }
            }

            Section("Note Type") {
                Picker("Type", selection: $model.selectedNotetypeId) {
                    ForEach(model.notetypeNames, id: \.id) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }
                .onChange(of: model.selectedNotetypeId) {
                    Task { await model.loadFields() }
                }
            }

            Section("Fields") {
                ForEach(Array(model.fieldNames.enumerated()), id: \.element) { index, name in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                        RichNoteFieldEditor(htmlText: $model[fieldAt: index], clozeTools: model.isClozeField(index))
                        if model.isClozeField(index) {
                            ClozeFieldSummary(html: model[fieldAt: index])
                        }
                    }
                }
            }

            Section("Tags") {
                TextField("Tags (space-separated)", text: $model.tags)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(palette.danger)
                        .amgiFont(.caption)
                }
            }
        }
    }
}

// MARK: - Cloze

/// Under a field cloze deletions go in: the cards they make, or how to
/// make the first.
struct ClozeFieldSummary: View {
    let html: String

    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: summary)
            .amgiFont(.caption)
            .foregroundStyle(palette.textSecondary)
    }

    private var summary: String {
        let numbers = ClozeEditing.numbers(in: html)
        guard !numbers.isEmpty else {
            return "Select the words to hide, then tap Cloze above the keyboard. Each number (c1, c2…) is a card of its own; Same Card hides more on the same card."
        }
        let cards = numbers.map { "c\($0)" }.joined(separator: ", ")
        return numbers.count == 1 ? "Makes 1 card: \(cards)" : "Makes \(numbers.count) cards: \(cards)"
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    // Seed the model directly: AddNoteContent has no `.task`, so the sample
    // fields aren't overwritten by a load and no live backend is touched.
    let model = AddNoteModel()
    model.decks = [.sample, .filtered]
    model.selectedDeckId = DeckInfo.sample.id
    model.notetypeNames = [(NotetypeID(1), "Basic"), (NotetypeID(2), "Cloze")]
    model.selectedNotetypeId = NotetypeID(1)
    model.fieldNames = ["Front", "Back"]
    model.fieldValues = ["안녕하세요", "Hello"]
    model.tags = "vocab korean"
    return NavigationStack {
        AddNoteContent(model: model)
            .navigationTitle("Add Note")
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
