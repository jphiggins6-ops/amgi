//
//  GraveyardSettingsSheet.swift
//  GraveyardFeature
//

import SwiftUI
import MnemonicCore

/// The OpenAI key (shared with the picture maker) and the text model.
/// Changes apply as they are made, so swiping the sheet away loses nothing.
struct GraveyardSettingsSheet: View {
    @State private var keyInput = ""
    @State private var hasKey = MnemonicAPIKey.load() != nil
    @State private var model = CardReviewSettings.model
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var trimmedKey: String {
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasKey {
                        LabeledContent("OpenAI key", value: "Saved ✓")
                        Button("Remove Key", role: .destructive) {
                            MnemonicAPIKey.delete()
                            hasKey = false
                        }
                    } else {
                        SecureField("Paste your key (sk-…)", text: $keyInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save Key") { saveKey() }
                            .disabled(trimmedKey.isEmpty)
                    }
                } header: {
                    Text("OpenAI API key")
                } footer: {
                    Text("The same key the Mnemonics pictures use. It's stored in this iPhone's Keychain and sent only to OpenAI, along with the card you ask about.")
                }

                Section {
                    TextField(CardReviewSettings.defaultModel, text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("AI model")
                } footer: {
                    Text("\(CardReviewSettings.defaultModel) is OpenAI's stronger model and costs about 1–2¢ per answer. gpt-6-luna is roughly twenty times cheaper but less careful. Only change this if you want a different model.")
                }
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: model) { _, newValue in CardReviewSettings.model = newValue }
            .alert(
                "Couldn't save the key",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                presenting: errorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
    }

    private func saveKey() {
        do {
            try MnemonicAPIKey.save(trimmedKey)
            keyInput = ""
            hasKey = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
