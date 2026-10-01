//
//  CardReviewAI.swift
//  GraveyardFeature
//

import Foundation
import AnkiKit
import Dependencies
import MnemonicCore

/// One turn of a card-review conversation.
struct CardReviewMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user, assistant
    }

    let id: UUID
    let role: Role
    /// What the conversation shows.
    let text: String
    /// Fields the assistant proposes to change; nil when it proposes none.
    let proposal: [ProposedField]?
    /// Exactly what was sent or received. Sent back as history, so the
    /// model sees its own earlier proposals, not a paraphrase of them.
    let raw: String

    init(id: UUID = UUID(), role: Role, text: String, proposal: [ProposedField]? = nil, raw: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.proposal = proposal
        self.raw = raw ?? text
    }
}

/// A complete new value for one field, named as the note type names it.
struct ProposedField: Equatable, Sendable, Codable {
    let name: String
    let value: String
}

/// The card as the assistant is shown it.
struct CardSnapshot: Equatable, Sendable {
    struct Field: Equatable, Sendable, Encodable {
        let name: String
        let value: String
    }

    let notetypeName: String
    let deckName: String
    let fields: [Field]
}

// MARK: - Prompt

enum CardReviewPrompt {
    /// What the conversation opens with, so the first answer arrives
    /// without the user having to type anything.
    static let opening = "Check this card. Is it correct and clear? If it needs fixing, propose a fixed version."

    /// Rebuilt before every request from the note as it is now, so a
    /// proposal that was applied is what the next answer sees.
    static func instructions(for card: CardSnapshot) -> String {
        """
        You help a medical student fix Anki flashcards they have flagged as defective. \
        Check the card for factual errors, ambiguity, missing context, and anything that \
        makes it hard to recall. Be direct and specific. When something is uncertain or \
        disputed, say so plainly instead of guessing.

        Always answer with one JSON object and nothing else, in this shape:
        {"reply": "what you say to the student, as plain text", \
        "proposed_fields": [{"name": "field name", "value": "complete new content"}]}

        Use "proposed_fields" only when you recommend changing the card; otherwise set it \
        to null. Name fields exactly as below, give each changed field's complete new \
        content, and leave unchanged fields out. Keep the card's HTML formatting, cloze \
        deletions such as {{c1::...}}, images (<img ...>), sound tags ([sound:...]) and \
        HTML comments exactly as they are, unless they are the problem. Start a new line \
        with <br>: a card ignores a plain line break.

        The card, a "\(card.notetypeName)" note in the deck "\(card.deckName)", \
        as its fields in order:
        \(fieldsJSON(card.fields))
        """
    }

    static func fieldsJSON(_ fields: [CardSnapshot.Field]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(fields) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Reply

enum CardReviewReply {
    struct Parsed: Equatable {
        let text: String
        let proposal: [ProposedField]?
    }

    private struct Body: Decodable {
        let reply: String
        let proposedFields: [ProposedField]?

        enum CodingKeys: String, CodingKey {
            case reply
            case proposedFields = "proposed_fields"
        }
    }

    /// Reads the JSON the instructions ask for, forgiving the code fences
    /// or stray words a model sometimes adds around it. Anything that still
    /// won't parse is shown as a plain reply with no proposal: an odd answer
    /// should read as an odd answer, not as an error.
    static func parse(_ content: String) -> Parsed {
        guard let json = jsonObject(in: content),
              let body = try? JSONDecoder().decode(Body.self, from: Data(json.utf8))
        else {
            return Parsed(text: content.trimmingCharacters(in: .whitespacesAndNewlines), proposal: nil)
        }
        let proposal = body.proposedFields.flatMap { $0.isEmpty ? nil : $0 }
        return Parsed(text: body.reply, proposal: proposal)
    }

    /// The outermost `{ … }` in the text.
    static func jsonObject(in content: String) -> String? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end
        else { return nil }
        return String(content[start...end])
    }
}

// MARK: - Applying a proposal

enum CardFieldEdits {
    /// The note with the proposed values in place, matching field names
    /// case-insensitively. Names the note type doesn't have are skipped —
    /// a model can misspell one — and `nil` means nothing would change.
    static func applying(_ proposal: [ProposedField], to note: NoteRecord, fieldNames: [String]) -> NoteRecord? {
        var fields = splitFields(note.flds)
        while fields.count < fieldNames.count { fields.append("") }
        var changed = false
        for proposed in proposal {
            let wanted = proposed.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = fieldNames.firstIndex(where: {
                $0.caseInsensitiveCompare(wanted) == .orderedSame
            }) else { continue }
            let value = storableValue(proposed.value)
            if fields[index] != value {
                fields[index] = value
                changed = true
            }
        }
        guard changed else { return nil }
        var updated = note
        updated.flds = fields.joined(separator: "\u{1f}")
        updated.sfld = fields.first ?? ""
        return updated
    }

    /// Proposed names the note type doesn't have, for telling the user
    /// what was left out.
    static func unknownNames(in proposal: [ProposedField], fieldNames: [String]) -> [String] {
        proposal.map(\.name).filter { name in
            let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !fieldNames.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        }
    }

    static func splitFields(_ flds: String) -> [String] {
        flds.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
    }

    /// A model sometimes writes a line break as a raw newline, which a card
    /// shows as a space; Anki's line break is `<br>`.
    static func storableValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

// MARK: - OpenAI

/// One call to OpenAI's Chat Completions endpoint. Building the request
/// and reading the response are pure, so both are tested without a key.
///
/// No `response_format`: GPT-6 models on Chat Completions only take a
/// strict JSON schema with reasoning switched off, and a card review is
/// worth the reasoning. The instructions ask for JSON and `CardReviewReply`
/// reads it leniently instead. No `temperature` either: reasoning models
/// reject anything but the default.
enum OpenAIChat {
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
        conversation: [CardReviewMessage],
        apiKey: String,
        model: String
    ) throws -> URLRequest {
        // Reasoning can take a minute or more; the default 60 s would cut
        // off answers that are already being paid for.
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let messages = [Message(role: "system", content: instructions)]
            + conversation.map { Message(role: $0.role.rawValue, content: $0.raw) }
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
            throw CardReviewError.service(message ?? "OpenAI answered with HTTP \(statusCode).")
        }
        guard let message = (try? JSONDecoder().decode(SuccessBody.self, from: body))?.choices.first?.message else {
            throw CardReviewError.service("OpenAI sent back an answer this app can't read.")
        }
        if let refusal = message.refusal, !refusal.isEmpty {
            throw CardReviewError.service(refusal)
        }
        let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            throw CardReviewError.service("OpenAI sent back an empty answer.")
        }
        return content
    }
}

// MARK: - Settings and errors

/// The text model. The API key is the one the picture maker already uses
/// (`MnemonicAPIKey`), so one key covers both.
enum CardReviewSettings {
    /// OpenAI's stronger GPT-6 model at the time of writing (September
    /// 2026): card content is medical, and accuracy is the whole point.
    static let defaultModel = "gpt-6-sol"
    static let modelKey = "graveyard_ai_model"

    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultModel : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
}

enum CardReviewError: LocalizedError, Equatable {
    case noKey
    case noteGone
    case service(String)
    case unimplemented

    var errorDescription: String? {
        switch self {
        case .noKey:
            "Add your OpenAI key first: tap the gear at the top of the Graveyard."
        case .noteGone:
            "This card's note no longer exists."
        case .service(let message):
            "OpenAI: \(message)"
        case .unimplemented:
            "The AI isn't available here."
        }
    }
}

// MARK: - Dependency

/// Sends a conversation and returns the assistant's raw text.
struct CardReviewAIClient: Sendable {
    var send: @Sendable (_ instructions: String, _ conversation: [CardReviewMessage]) async throws -> String
}

extension CardReviewAIClient: DependencyKey {
    static let liveValue = CardReviewAIClient { instructions, conversation in
        guard let apiKey = MnemonicAPIKey.load() else { throw CardReviewError.noKey }
        let request = try OpenAIChat.makeRequest(
            instructions: instructions,
            conversation: conversation,
            apiKey: apiKey,
            model: CardReviewSettings.model
        )
        let (body, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try OpenAIChat.content(from: body, statusCode: statusCode)
    }

    static let testValue = CardReviewAIClient { _, _ in throw CardReviewError.unimplemented }
}

extension DependencyValues {
    var cardReviewAI: CardReviewAIClient {
        get { self[CardReviewAIClient.self] }
        set { self[CardReviewAIClient.self] = newValue }
    }
}
