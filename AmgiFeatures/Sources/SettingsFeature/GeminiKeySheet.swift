//
//  GeminiKeySheet.swift
//  SettingsFeature
//

import SwiftUI
import Foundation
import Dependencies
import MnemonicCore

/// Settings → Review → AI Voice → Gemini Key: pasting, testing or removing
/// the Google Gemini key the AI voice uses. It goes straight into the
/// Keychain and is never shown again, only what kind of key it is.
struct GeminiKeySheet: View {
    @State private var keyInput = ""
    /// The saved key's kind, nil when there's none.
    @State private var savedKind = GeminiAPIKey.load().map(GeminiAPIKey.kind(of:))
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var testResult: String?
    @Dependency(\.cardVoice) private var cardVoice
    @Environment(\.dismiss) private var dismiss

    /// The test rewrites this, as hands-free would.
    private static let sampleCard = CardScript.Card(
        question: "[...] is the drug of choice for absence seizures.",
        answer: "Ethosuximide.",
        deckName: "Neurology"
    )

    private var trimmedKey: String {
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let savedKind {
                        LabeledContent("Gemini key", value: savedKind == .standard ? "Saved, older kind" : "Saved ✓")
                        if savedKind == .standard {
                            Text("This key starts with “AIza”, the older kind, which Google stopped accepting for Gemini in September 2026. Remove it, then make a new key at aistudio.google.com/apikey: new keys start with “AQ.”.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Button {
                            test()
                        } label: {
                            HStack {
                                Text("Test Key")
                                if isTesting {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isTesting)
                        Button("Remove Key", role: .destructive) {
                            GeminiAPIKey.delete()
                            self.savedKind = nil
                            testResult = nil
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
                    Text("Make one at aistudio.google.com/apikey (it starts with “AQ.”), then copy it and paste it here. It's kept in this iPhone's Keychain and sent only to Google, with the text of the cards being read. Turn on billing for it in Google AI Studio: without billing, Google allows only a handful of recordings a day.")
                }

                if let testResult {
                    Section("Test") {
                        Text(testResult)
                            .textSelection(.enabled)
                    }
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
            savedKind = GeminiAPIKey.kind(of: trimmedKey)
            keyInput = ""
            testResult = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Has Gemini rewrite a sample card, which costs a hundredth of a cent
    /// and shows the key works, or Google's reason it doesn't.
    private func test() {
        isTesting = true
        testResult = nil
        let cardVoice = self.cardVoice
        Task {
            do {
                let lines = try await cardVoice.script(Self.sampleCard)
                testResult = "Your key works. Gemini turned the sample card “[...] is the drug of choice for absence seizures” into: “\(lines.question)”"
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}
