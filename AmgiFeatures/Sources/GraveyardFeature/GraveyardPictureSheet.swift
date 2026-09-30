//
//  GraveyardPictureSheet.swift
//  GraveyardFeature
//

import SwiftUI
import AnkiKit
import Dependencies
import MnemonicCore
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// What kind of picture to ask for.
enum GraveyardPictureStyle: String, CaseIterable, Identifiable {
    case diagram, mnemonic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diagram: "Diagram"
        case .mnemonic: "Mnemonic"
        }
    }

    var explanation: String {
        switch self {
        case .diagram: "A clear, accurate picture of what the card is about."
        case .mnemonic: "A bold, slightly absurd scene that makes the fact stick."
        }
    }

    var prompt: String {
        switch self {
        case .diagram: MnemonicPromptStyle.diagram
        case .mnemonic: MnemonicPromptStyle.default
        }
    }
}

@Observable
@MainActor
final class GraveyardPictureModel {
    let noteId: NoteID
    var idea: String
    var style: GraveyardPictureStyle = .diagram
    private(set) var image: MnemonicImage?
    private(set) var isGenerating = false
    private(set) var isSaving = false
    var errorMessage: String?
    /// No key means the generator makes free placeholder squares.
    let usesPlaceholder = MnemonicAPIKey.load() == nil

    @ObservationIgnored @Dependency(\.mnemonicImageGenerator) private var generator
    @ObservationIgnored @Dependency(\.mnemonicClient) private var mnemonics

    init(noteId: NoteID, idea: String) {
        self.noteId = noteId
        self.idea = idea
    }

    private var trimmedIdea: String {
        idea.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canGenerate: Bool { !trimmedIdea.isEmpty && !isGenerating && !isSaving }

    func generate() async {
        guard canGenerate else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            image = try await generator.generate(MnemonicImageRequest(idea: trimmedIdea, style: style.prompt))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adds the picture to the note's extra field. True when it's saved.
    func save() async -> Bool {
        guard let image, !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await mnemonics.attach(noteId, trimmedIdea, image)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Makes a picture for a flagged card and adds it to the card's Extra
/// field (or Back Extra, or Back — wherever the note type keeps extras).
struct GraveyardPictureSheet: View {
    @State private var model: GraveyardPictureModel
    @Environment(\.dismiss) private var dismiss

    init(noteId: NoteID, suggestedIdea: String) {
        _model = State(initialValue: GraveyardPictureModel(noteId: noteId, idea: suggestedIdea))
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.usesPlaceholder {
                    Section {
                        Label(
                            "No OpenAI key is saved, so pictures are free placeholder squares. Add a key with the gear on the Graveyard screen.",
                            systemImage: "info.circle"
                        )
                    }
                }

                Section {
                    TextField("What should the picture show?", text: $model.idea, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Picture")
                } footer: {
                    Text("Describe it in your own words. This description is sent to OpenAI.")
                }

                Section {
                    Picker("Style", selection: $model.style) {
                        ForEach(GraveyardPictureStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(model.style.explanation)
                }

                Section {
                    if model.isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Making the picture… this can take a minute.")
                                .foregroundStyle(.secondary)
                        }
                    } else if let image = model.image.flatMap(Self.decoded) {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Button(generateTitle) {
                        Task { await model.generate() }
                    }
                    .disabled(!model.canGenerate)
                }
            }
            .navigationTitle("Add a Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Card") {
                        Task {
                            if await model.save() { dismiss() }
                        }
                    }
                    .disabled(model.image == nil || model.isGenerating || model.isSaving)
                }
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
    }

    private var generateTitle: String {
        model.image == nil ? "Generate" : "Try Again"
    }

    private static func decoded(_ image: MnemonicImage) -> Image? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: image.data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}
