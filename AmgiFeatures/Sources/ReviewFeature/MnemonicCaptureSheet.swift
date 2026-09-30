//
//  MnemonicCaptureSheet.swift
//  ReviewFeature
//

import SwiftUI
import AnkiKit
import Dependencies
import Foundation
import MnemonicCore

/// The ✨ sheet: one line, Return to save, straight back to reviewing.
///
/// Deliberately does nothing but write the idea onto the note. Pictures are
/// made later, from the Mnemonics screen — making one here would put a wait
/// in the middle of a review session, which is the one thing this feature
/// exists to avoid.
struct MnemonicCaptureSheet: View {
    let note: NoteRecord
    let onSaved: () -> Void

    @Dependency(\.mnemonicClient) private var mnemonicClient
    @State private var idea = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmedIdea: String {
        idea.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A giant anchor made of ice…", text: $idea)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } header: {
                    Text(MnemonicText.summary(note.sfld, limit: 90))
                        .textCase(nil)
                        .lineLimit(2)
                } footer: {
                    Text("Saved on this card. Make the picture later from Library → ••• → Mnemonics.")
                }
            }
            .navigationTitle("Visual Mnemonic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedIdea.isEmpty || isSaving)
                }
            }
            .alert(
                "Couldn't save the idea",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                presenting: errorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
        .presentationDetents([.medium])
        .onAppear { isFocused = true }
    }

    private func save() {
        let idea = trimmedIdea
        guard !idea.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await mnemonicClient.capture(note.id, idea)
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
