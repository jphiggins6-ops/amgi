//
//  CardExplainerTests.swift
//  MnemonicCoreTests
//

import Foundation
import Testing
@testable import MnemonicCore

@Suite struct CardExplainerTests {

    @Test func aRenderedSideBecomesReadableText() {
        let html = """
        <style>.card { color: red }</style><script>var x = "<b>no</b>";</script>
        <div class="card">Ptosis &amp; miosis<br>Horner's<!-- note --></div>
        <hr id=answer><img src="eye.jpg"> [sound:eye.mp3]
        """
        #expect(CardPlainText.from(html: html) == "Ptosis & miosis\nHorner's\n[picture] [sound]")
    }

    @Test func longSidesAreTrimmed() {
        let text = CardPlainText.from(html: String(repeating: "a", count: 50), limit: 10)
        #expect(text == "aaaaaaaaa…")
    }

    @Test func theRequestCarriesTheCardAndTheConversation() throws {
        let card = CardExplanation.Card(question: "Ptosis, miosis, anhidrosis?", answer: "Horner syndrome", deckName: "Neuro")
        let conversation = [
            CardExplanation.Message(role: .user, text: CardExplanation.opening),
            CardExplanation.Message(role: .assistant, text: "Sympathetic chain lesion."),
            CardExplanation.Message(role: .user, text: "Why no sweating?"),
        ]
        let request = try OpenAIText.makeRequest(
            instructions: CardExplanation.instructions(for: card),
            conversation: conversation,
            apiKey: "sk-test",
            model: "gpt-6-sol"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try JSONDecoder().decode(OpenAIText.RequestBody.self, from: try #require(request.httpBody))
        #expect(body.model == "gpt-6-sol")
        #expect(body.messages.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(body.messages[0].content.contains("Horner syndrome"))
        #expect(body.messages[0].content.contains("\"Neuro\""))
        #expect(body.messages[3].content == "Why no sweating?")
    }

    @Test func theReplyOrOpenAIsOwnErrorComesBack() throws {
        let ok = Data(#"{"choices":[{"message":{"content":"  Because… "}}]}"#.utf8)
        #expect(try OpenAIText.content(from: ok, statusCode: 200) == "Because…")

        let bad = Data(#"{"error":{"message":"Incorrect API key provided."}}"#.utf8)
        #expect(throws: CardExplanationError.service("Incorrect API key provided.")) {
            try OpenAIText.content(from: bad, statusCode: 401)
        }
    }
}
