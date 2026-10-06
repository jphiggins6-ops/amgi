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
///
/// Like Anki's Add window it stays open after each note: an "Added" toast,
/// the fields not pinned start empty, and the cursor goes to the first of
/// them. `onSave` is told of each note; a caller adding just one closes the
/// sheet from there.
package struct AddNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: AddNoteModel
    @State private var showDiscardConfirm = false
    @State private var showAddedConfirmation = false
    @State private var addedToastTask: Task<Void, Never>?
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
                    // Note type and deck as two small menus, in place of
                    // two sections of the form.
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: AmgiSpacing.sm) {
                            ChoiceChip(
                                title: "Note Type",
                                systemImage: "rectangle.on.rectangle",
                                choices: model.notetypeNames,
                                selection: $model.selectedNotetypeId
                            )
                            ChoiceChip(
                                title: "Deck",
                                systemImage: "tray.full",
                                choices: model.addableDecks.map { (id: $0.id, name: $0.name) },
                                selection: $model.selectedDeckId,
                                showsLastPartOnly: true
                            )
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.addedCount > 0 ? "Done" : "Cancel") {
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
                                    model.startNextNote()
                                    showAdded()
                                }
                            }
                        }
                        .disabled(model.isSaving || !model.hasNewContent)
                    }
                }
                .overlay { addedToast }
                .sensoryFeedback(.success, trigger: model.addedCount)
                // Up front rather than at the foot of the form, where the
                // keyboard would cover it.
                .alert("Couldn’t Add", isPresented: addFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(verbatim: model.errorMessage ?? "")
                }
                .task { await model.loadData() }
        }
    }
}

// MARK: - Added

private extension AddNoteView {
    var addFailed: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    func showAdded() {
        addedToastTask?.cancel()
        addedToastTask = Task {
            withAnimation(AmgiMotion.momentum) { showAddedConfirmation = true }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(AmgiMotion.standard) { showAddedConfirmation = false }
        }
    }

    @ViewBuilder
    var addedToast: some View {
        if showAddedConfirmation {
            VStack {
                Spacer()
                Text(verbatim: model.addedCount > 1 ? "Added · \(model.addedCount) so far" : "Added")
                    .amgiFont(.bodyEmphasis)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .amgiMaterial(.light, in: Capsule())
                    .padding(.bottom, 32)
            }
            .allowsHitTesting(false)
            .transition(AmgiMotion.slide(from: .bottom))
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
            Section {
                ForEach(Array(model.fieldNames.enumerated()), id: \.element) { index, name in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(name)
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                            Spacer(minLength: 0)
                            PinFieldButton(fieldName: name, isPinned: model.isPinned(index)) {
                                model.togglePin(index)
                            }
                        }
                        RichNoteFieldEditor(
                            htmlText: $model[fieldAt: index],
                            clozeTools: model.isClozeField(index),
                            focusOnAppear: model.addedCount > 0 && index == model.firstUnpinnedFieldIndex
                        )
                        // Made again for each new note: an editor being
                        // typed in doesn't take outside changes.
                        .id(model.addedCount)
                        if model.isClozeField(index) {
                            ClozeFieldSummary(html: model[fieldAt: index])
                        }
                    }
                }
            } footer: {
                Text("Pinned fields keep what's in them for the next note.")
            }

            Section {
                TagsRow(tags: $model.tags)
            }
        }
        .onChange(of: model.selectedNotetypeId) {
            Task { await model.loadFields() }
        }
    }
}

// MARK: - Compact rows

/// A small menu in the top bar for one choice, such as the note type or the
/// deck: an icon and the choice's name; a tap lists them all, the current
/// one ticked. A part of the bar instead of a section of the form.
struct ChoiceChip<ID: Hashable>: View {
    let title: String
    let systemImage: String
    let choices: [(id: ID, name: String)]
    @Binding var selection: ID
    /// Just the last part of a name like "Medicine::Cardiology", as a deck's.
    var showsLastPartOnly = false

    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(choices, id: \.id) { choice in
                    Text(verbatim: choice.name).tag(choice.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                Text(verbatim: shownName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.accent)
            .frame(maxWidth: 150)
        }
        .accessibilityLabel(title)
        .accessibilityValue(currentName)
    }

    private var currentName: String {
        choices.first { $0.id == selection }?.name ?? "Choose"
    }

    private var shownName: String {
        guard showsLastPartOnly, let last = currentName.split(separator: "::").last else { return currentName }
        return String(last)
    }
}

/// Tags in a single row, with no section header.
struct TagsRow: View {
    @Binding var tags: String

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.sm) {
            Image(systemName: "tag")
                .foregroundStyle(palette.textTertiary)
                .accessibilityHidden(true)
            TextField("Tags, separated by spaces", text: $tags)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
}

// MARK: - Pinning

/// The pin by a field's name: a pinned field keeps what's in it from one
/// new note to the next.
private struct PinFieldButton: View {
    let fieldName: String
    let isPinned: Bool
    let toggle: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .imageScale(.small)
                .foregroundStyle(isPinned ? palette.accent : palette.textTertiary)
                .frame(minWidth: 32, minHeight: 24)
                .contentShape(Rectangle())
        }
        // Only the pin takes the tap, not the whole row.
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("A pinned field keeps what's in it for the next note")
    }

    private var accessibilityTitle: String {
        isPinned ? "Unpin \(fieldName)" : "Pin \(fieldName)"
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
            return "Select words to hide, then tap Cloze above the keyboard."
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
