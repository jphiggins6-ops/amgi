//
//  CardReviewChatView.swift
//  GraveyardFeature
//

import SwiftUI
import AnkiClients
import AnkiKit
import Dependencies
import MnemonicCore
import Observation

@Observable
@MainActor
final class CardReviewChatModel {
    let noteId: NoteID
    let deckName: String
    /// The card as the last request showed it.
    private(set) var card: CardSnapshot?
    private(set) var messages: [CardReviewMessage] = []
    private(set) var isSending = false
    private(set) var isApplying = false
    /// Replies whose proposal is on the card now.
    private(set) var applied: Set<UUID> = []
    var draft = ""
    var errorMessage: String?
    /// A question that failed to send, for Try Again.
    private(set) var failedQuestion: String?

    @ObservationIgnored @Dependency(\.cardReviewAI) private var ai
    @ObservationIgnored @Dependency(\.noteClient) private var noteClient
    @ObservationIgnored @Dependency(\.notetypesClient) private var notetypesClient

    init(noteId: NoteID, deckName: String) {
        self.noteId = noteId
        self.deckName = deckName
    }

    /// Opens with a check of the card, so the first answer needs no typing.
    func start() async {
        guard messages.isEmpty, !isSending else { return }
        await ask(CardReviewPrompt.opening)
    }

    func sendDraft() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        draft = ""
        await ask(question)
    }

    func retry() async {
        guard let question = failedQuestion, !isSending else { return }
        await ask(question)
    }

    private func ask(_ question: String) async {
        let message = CardReviewMessage(role: .user, text: question)
        messages.append(message)
        isSending = true
        errorMessage = nil
        failedQuestion = nil
        defer { isSending = false }
        do {
            let card = try await loadCard()
            self.card = card
            let content = try await ai.send(CardReviewPrompt.instructions(for: card), messages)
            let parsed = CardReviewReply.parse(content)
            messages.append(CardReviewMessage(
                role: .assistant,
                text: parsed.text,
                proposal: parsed.proposal,
                raw: content
            ))
        } catch {
            // Take the unanswered question back off, so Try Again doesn't
            // send it twice.
            messages.removeAll { $0.id == message.id }
            failedQuestion = question
            errorMessage = error.localizedDescription
        }
    }

    /// Writes a reply's proposed fields onto the note, starting from the
    /// note as it is now rather than from the copy the reply was based on.
    func apply(_ message: CardReviewMessage) async {
        guard let proposal = message.proposal, !isApplying, !applied.contains(message.id) else { return }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }
        do {
            guard let note = try await noteClient.fetch(noteId) else { throw CardReviewError.noteGone }
            let fieldNames = try await notetypesClient.get(note.mid).fields.map(\.name)
            let unknown = CardFieldEdits.unknownNames(in: proposal, fieldNames: fieldNames)
            guard let updated = CardFieldEdits.applying(proposal, to: note, fieldNames: fieldNames) else {
                applied.insert(message.id)
                errorMessage = unknown.isEmpty
                    ? "Those changes are already on the card."
                    : "Nothing was changed: this card has no field called \(unknown.joined(separator: ", "))."
                return
            }
            try await noteClient.save(updated)
            applied.insert(message.id)
            if !unknown.isEmpty {
                errorMessage = "Applied, except for \(unknown.joined(separator: ", ")), which this card doesn't have."
            }
            card = try? await loadCard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCard() async throws -> CardSnapshot {
        guard let note = try await noteClient.fetch(noteId) else { throw CardReviewError.noteGone }
        let notetype = try await notetypesClient.get(note.mid)
        return CardSnapshots.make(note: note, notetype: notetype, deckName: deckName)
    }
}

/// A conversation with the AI about one flagged card.
struct CardReviewChatView: View {
    @State private var model: CardReviewChatModel
    @Environment(\.dismiss) private var dismiss

    init(noteId: NoteID, deckName: String) {
        _model = State(initialValue: CardReviewChatModel(noteId: noteId, deckName: deckName))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageView(
                                message: message,
                                currentFields: model.card?.fields ?? [],
                                isApplied: model.applied.contains(message.id),
                                isApplying: model.isApplying,
                                onApply: { Task { await model.apply(message) } }
                            )
                            .id(message.id)
                        }
                        if model.isSending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Thinking… this can take a minute.")
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                        if let error = model.errorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                                if model.failedQuestion != nil {
                                    Button("Try Again") { Task { await model.retry() } }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .id("error")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { _, _ in
                    guard let last = model.messages.last?.id else { return }
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: model.isSending) { _, sending in
                    if sending { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.start() }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a follow-up question…", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await model.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(model.isSending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageView: View {
    let message: CardReviewMessage
    let currentFields: [CardSnapshot.Field]
    let isApplied: Bool
    let isApplying: Bool
    let onApply: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                Text(message.text)
                    .textSelection(.enabled)
                if let proposal = message.proposal {
                    ProposalView(
                        proposal: proposal,
                        currentFields: currentFields,
                        isApplied: isApplied,
                        isApplying: isApplying,
                        onApply: onApply
                    )
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The fields a reply wants to change, before and after, and the button
/// that writes them to the card.
private struct ProposalView: View {
    let proposal: [ProposedField]
    let currentFields: [CardSnapshot.Field]
    let isApplied: Bool
    let isApplying: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested changes")
                .font(.headline)
            ForEach(Array(proposal.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !isApplied, let current = currentValue(of: field.name) {
                        Text(MnemonicText.summary(current, limit: 2000))
                            .strikethrough()
                            .foregroundStyle(.secondary)
                    }
                    Text(MnemonicText.summary(field.value, limit: 2000))
                }
            }
            if isApplied {
                Label("Applied to the card", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(action: onApply) {
                    Label("Apply to Card", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func currentValue(of name: String) -> String? {
        currentFields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
