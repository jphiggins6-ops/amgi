//
//  GeminiKeySheet.swift
//  SettingsFeature
//

import SwiftUI
import Foundation
import MnemonicCore

/// Settings → Review → AI Voice → Gemini Key: pasting, or removing, the
/// Google Gemini key the AI voice uses. It goes straight into the Keychain.
struct GeminiKeySheet: View {
    @State private var keyInput = ""
    @State private var hasKey = GeminiAPIKey.load() != nil
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
                        LabeledContent("Gemini key", value: "Saved ✓")
                        Button("Remove Key", role: .destructive) {
                            GeminiAPIKey.delete()
                            hasKey = false
                        }
                    } else {
                        SecureField("Paste your key", text: $keyInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save Key") { saveKey() }
                            .disabled(trimmedKey.isEmpty)
                    }
                } header: {
                    Text("Google Gemini API key")
                } footer: {
                    Text("Make one at aistudio.google.com/apikey, then copy it and paste it here. It's kept in this iPhone's Keychain and sent only to Google, with the text of the cards being read. Turn on billing for it in Google AI Studio: without billing, Google allows only a handful of recordings a day.")
                }
            }
            .navigationTitle("Gemini Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
            try GeminiAPIKey.save(trimmedKey)
            keyInput = ""
            hasKey = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
