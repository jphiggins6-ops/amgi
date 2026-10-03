//
//  CardExplainer.swift
//  MnemonicCore
//

public import Foundation
public import Dependencies

/// "Explain" while reviewing: one tap asks OpenAI why the card's answer is
/// right, with the key context, and follow-up questions continue the
/// conversation. Uses the key the pictures and the Graveyard use
/// (`MnemonicAPIKey`) and the Graveyard's choice of text model.
///
/// Lives in this sink so the review screen can reach it without depending
/// on the Graveyard.
public enum CardExplanation {
    /// One turn of the conversation.
    public struct Message: Identifiable, Equatable, Sendable {
        public enum Role: String, Sendable {
            case user, assistant
        }

        public let id: UUID
        public let role: Role
        public let text: String

        public init(id: UUID = UUID(), role: Role, text: String) {
            self.id = id
            self.role = role
            self.text = text
        }
    }

    /// The card as the explanation is asked about: what each side shows.
    public struct Card: Equatable, Sendable, Identifiable {
        public let question: String
        public let answer: String
        public let deckName: String

        public var id: String { question + "\u{1f}" + answer }

        public init(question: String, answer: String, deckName: String) {
            self.question = question
            self.answer = answer
            self.deckName = deckName
        }

        /// Built from the card's rendered sides, which can carry styles,
        /// scripts and the question repeated above the answer.
        public init(questionHTML: String, answerHTML: String, deckName: String) {
            self.init(
                question: CardPlainText.from(html: questionHTML),
                answer: CardPlainText.from(html: answerHTML),
                deckName: deckName
            )
        }
    }

    /// What the conversation opens with, so the explanation arrives without
    /// anything typed.
    public static let opening = "Explain why this answer is right."

    public static func instructions(for card: Card) -> String {
        """
        You are a tutor helping a medical student who has just reviewed an Anki \
        flashcard. Explain why the answer is right: the key reasoning or mechanism, \
        the essential context around it, and, if it helps, one memorable way to tie \
        it together. Be accurate and concise, about 150 words unless asked for more. \
        If the card looks wrong, outdated or ambiguous, say so plainly. Write plain \
        text with simple Markdown only (bold, italics, short bullet lists), no headings. \
        Answer follow-up questions the same way.

        The card is in the deck "\(card.deckName)". Its question side shows:
        \(card.question)

        Its answer side shows:
        \(card.answer)
        """
    }
}

// MARK: - Plain text

public enum CardPlainText {
    /// A rendered card side as readable text: styles, scripts and comments
    /// dropped, pictures and sounds marked, line breaks kept, entities
    /// decoded, and trimmed to `limit` characters.
    public static func from(html: String, limit: Int = 6_000) -> String {
        var text = html
        text = replacing(#"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, in: text, with: " ")
        text = replacing(#"(?s)<!--.*?-->"#, in: text, with: " ")
        text = replacing(#"(?i)<img\b[^>]*>"#, in: text, with: " [picture] ")
        text = replacing(#"\[sound:[^\]]*\]"#, in: text, with: " [sound] ")
        text = replacing(#"(?i)<br\s*/?>|</(div|p|li|tr|h[1-6])\s*>|<hr\b[^>]*>"#, in: text, with: "\n")
        text = replacing(#"<[^>]*>"#, in: text, with: " ")
        // &amp; last, or "&amp;lt;" would decode twice.
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        text = lines.joined(separator: "\n")
        if text.count > limit {
            text = String(text.prefix(max(limit - 1, 0))) + "…"
        }
        return text
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}

// MARK: - OpenAI

/// One call to OpenAI's Chat Completions endpoint. Building the request and
/// reading the response are pure, so both are tested without a key. No
/// `response_format` or `temperature`, for the reasons the Graveyard's
/// client gives: GPT-6 reasoning models take neither as this uses them.
public enum OpenAIText {
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    struct RequestBody: Codable, Equatable {
        let model: String
        let messages: [Message]
    }

    static func makeRequest(
        instructions: String,
        conversation: [CardExplanation.Message],
        apiKey: String,
        model: String
    ) throws -> URLRequest {
        // Reasoning can take a minute or more.
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let messages = [Message(role: "system", content: instructions)]
            + conversation.map { Message(role: $0.role.rawValue, content: $0.text) }
        request.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages))
        return request
    }

    private struct SuccessBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let refusal: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    /// The assistant's text, or an error carrying OpenAI's own explanation.
    static func content(from body: Data, statusCode: Int) throws -> String {
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error.message
            throw CardExplanationError.service(message ?? "OpenAI answered with HTTP \(statusCode).")
        }
        guard let message = (try? JSONDecoder().decode(SuccessBody.self, from: body))?.choices.first?.message else {
            throw CardExplanationError.service("OpenAI sent back an answer this app can't read.")
        }
        if let refusal = message.refusal, !refusal.isEmpty {
            throw CardExplanationError.service(refusal)
        }
        let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            throw CardExplanationError.service("OpenAI sent back an empty answer.")
        }
        return content
    }

    /// The Graveyard's text model setting, shared so one choice covers both.
    static let modelKey = "graveyard_ai_model"
    static let defaultModel = "gpt-6-sol"

    static var model: String {
        let stored = UserDefaults.standard.string(forKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultModel : stored
    }
}

public enum CardExplanationError: LocalizedError, Equatable {
    case noKey
    case service(String)
    case unimplemented

    public var errorDescription: String? {
        switch self {
        case .noKey:
            "Add your OpenAI key first: open the Graveyard tab and tap the gear."
        case .service(let message):
            "OpenAI: \(message)"
        case .unimplemented:
            "The AI isn't available here."
        }
    }
}

// MARK: - Dependency

/// Sends the conversation so far and returns the assistant's next reply.
public struct CardExplainerClient: Sendable {
    public var send: @Sendable (_ card: CardExplanation.Card, _ conversation: [CardExplanation.Message]) async throws -> String

    public init(send: @escaping @Sendable (_ card: CardExplanation.Card, _ conversation: [CardExplanation.Message]) async throws -> String) {
        self.send = send
    }
}

extension CardExplainerClient: DependencyKey {
    public static let liveValue = CardExplainerClient { card, conversation in
        guard let apiKey = MnemonicAPIKey.load() else { throw CardExplanationError.noKey }
        let request = try OpenAIText.makeRequest(
            instructions: CardExplanation.instructions(for: card),
            conversation: conversation,
            apiKey: apiKey,
            model: OpenAIText.model
        )
        let (body, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try OpenAIText.content(from: body, statusCode: statusCode)
    }

    public static let testValue = CardExplainerClient { _, _ in throw CardExplanationError.unimplemented }
}

extension DependencyValues {
    public var cardExplainer: CardExplainerClient {
        get { self[CardExplainerClient.self] }
        set { self[CardExplainerClient.self] = newValue }
    }
}
