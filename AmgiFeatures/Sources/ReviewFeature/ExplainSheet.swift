//
//  ExplainSheet.swift
//  ReviewFeature
//

import SwiftUI
import Dependencies
import Foundation
import MnemonicCore
import Theme

/// "Explain": why the card's answer is right, from OpenAI, the moment the
/// sheet opens. Follow-up questions continue the conversation. Closing the
/// sheet goes straight back to the card.
struct ExplainSheet: View {
    let card: CardExplanation.Card

    @Dependency(\.cardExplainer) private var explainer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var messages: [CardExplanation.Message] = []
    @State private var isThinking = false
    @State private var errorMessage: String?
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                        Text(verbatim: MnemonicText.summary(card.question, limit: 160))
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)

                        ForEach(shownMessages) { message in
                            bubble(message)
                                .id(message.id)
                        }

                        if isThinking {
                            HStack(spacing: AmgiSpacing.sm) {
                                ProgressView()
                                Text("Thinking…")
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.textSecondary)
                            }
                            .id("thinking")
                        }

                        if let errorMessage {
                            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                                Text(verbatim: errorMessage)
                                    .amgiFont(.body)
                                    .foregroundStyle(palette.danger)
                                Button("Try Again") { Task { await send() } }
                                    .buttonStyle(.bordered)
                            }
                            .id("error")
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: messages.count) { _, _ in
                    guard let last = messages.last?.id else { return }
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: isThinking) { _, thinking in
                    if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Explain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            if messages.isEmpty { await ask(CardExplanation.opening) }
        }
    }

    /// Everything but the opening request, which the user never typed.
    private var shownMessages: [CardExplanation.Message] {
        messages.enumerated()
            .filter { $0.offset > 0 || $0.element.role == .assistant }
            .map(\.element)
    }

    private func bubble(_ message: CardExplanation.Message) -> some View {
        let isUser = message.role == .user
        return Text(Self.formatted(message.text))
            .amgiFont(.body)
            .foregroundStyle(palette.textPrimary)
            .textSelection(.enabled)
            .padding(isUser ? AmgiSpacing.md : 0)
            .background(
                isUser ? palette.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
            )
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: AmgiSpacing.sm) {
            TextField("Ask a follow-up…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($draftFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(trimmedDraft.isEmpty || isThinking)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, AmgiSpacing.sm)
        .background(.bar)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendDraft() {
        let question = trimmedDraft
        guard !question.isEmpty, !isThinking else { return }
        draft = ""
        Task { await ask(question) }
    }

    private func ask(_ text: String) async {
        messages.append(CardExplanation.Message(role: .user, text: text))
        await send()
    }

    /// Sends the conversation as it stands; after a failure, the same
    /// question goes again.
    private func send() async {
        guard !isThinking else { return }
        isThinking = true
        errorMessage = nil
        defer { isThinking = false }
        do {
            let reply = try await explainer.send(card, messages)
            messages.append(CardExplanation.Message(role: .assistant, text: reply))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Bold, italics and line breaks from the reply's simple Markdown.
    static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
