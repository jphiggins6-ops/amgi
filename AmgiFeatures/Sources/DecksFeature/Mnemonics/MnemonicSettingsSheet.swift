//
//  MnemonicSettingsSheet.swift
//  DecksFeature
//

import SwiftUI
import Foundation
import MnemonicCore

/// OpenAI key, picture quality, model. Changes apply as they're made, so
/// swiping the sheet away loses nothing.
struct MnemonicSettingsSheet: View {
    @State private var keyInput = ""
    @State private var hasKey = MnemonicAPIKey.load() != nil
    @State private var quality = MnemonicSettings.quality
    @State private var model = MnemonicSettings.model
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
                    Text("Stored in this iPhone's Keychain and sent only to OpenAI. Create one at platform.openai.com → API keys — and set a monthly spending limit there. Without a key, drafts are free placeholder squares.")
                }

                Section {
                    Picker("Quality", selection: $quality) {
                        ForEach(MnemonicSettings.Quality.allCases) { option in
                            Text("\(option.rawValue.capitalized) — \(option.roughCost)").tag(option)
                        }
                    }
                } header: {
                    Text("Picture quality")
                } footer: {
                    Text("Rough cost per picture. You only pay when you tap Generate or Try Again. OpenAI's pricing page has current prices.")
                }

                Section {
                    TextField(MnemonicSettings.defaultModel, text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Model")
                } footer: {
                    Text("Leave this alone unless OpenAI retires the model.")
                }
            }
            .navigationTitle("Picture Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: quality) { _, newValue in MnemonicSettings.quality = newValue }
            .onChange(of: model) { _, newValue in MnemonicSettings.model = newValue }
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
